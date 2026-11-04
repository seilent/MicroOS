#!/usr/bin/env python3
import contextlib
import fcntl
import hashlib
import importlib.machinery
import importlib.util
import io
import json
import os
import shutil
import signal
import stat
import struct
import subprocess
import sys
import tempfile

TREE = sys.argv[1]
TOOL = os.path.join(TREE, "usr/libexec/microos/microos-abl")
LOOP = ""
if "--loop" in sys.argv:
    LOOP = sys.argv[sys.argv.index("--loop") + 1]

CASES = []
FAILED = []


def case(fn):
    CASES.append(fn)
    return fn


def need(cond, msg):
    if not cond:
        raise AssertionError(msg)


def sha(data):
    return hashlib.sha256(data).hexdigest()


def make_elf(body=b"CODE" * 64, sections=2, phnum=2, claim=0):
    phoff = 52
    phentsize = 32
    base = phoff + phentsize * phnum
    shoff = base + len(body)
    shentsize = 40
    total = shoff + shentsize * sections
    data = bytearray(total)
    data[:4] = b"\x7fELF"
    data[4] = 1
    data[5] = 1
    data[6] = 1
    struct.pack_into("<I", data, 28, phoff)
    struct.pack_into("<H", data, 42, phentsize)
    struct.pack_into("<H", data, 44, phnum)
    struct.pack_into("<I", data, 32, shoff)
    struct.pack_into("<H", data, 46, shentsize)
    struct.pack_into("<H", data, 48, sections)
    end = base + len(body)
    if claim:
        end = claim
    struct.pack_into("<I", data, phoff + 4, 0)
    if claim <= len(data):
        struct.pack_into("<I", data, phoff + 16, claim or base + len(body))
    else:
        struct.pack_into("<I", data, phoff + 16, claim)
    data[base:base + len(body)] = body
    length = max(end, shoff + shentsize * sections)
    return bytes(data), length


def catalog_row(order, version, length, digest):
    return f"{order}\t{version}\tSM8250\t{length}\t{digest}\n"


HEADER = "order\tversion\tsoc\tlength\tsha256\n"


def write(path, data, mode=0o644):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(data if isinstance(data, bytes) else data.encode())
    os.chmod(path, mode)


STUBS = {
    "systemd-inhibit": """#!/usr/bin/env bash
printf 'inhibit %s\\n' "$*" >> "$CALLS"
while [[ $# -gt 0 ]]; do
  case $1 in
    --what=*|--mode=*|--who=*|--why=*) shift ;;
    *) break ;;
  esac
done
MICROOS_ABL_INHIBITED=1 exec "$@"
""",
    "bootimg-update": """#!/usr/bin/env bash
printf 'bootimg %s\\n' "$*" >> "$CALLS"
exit "$(cat "$STUB_DIR/bootimg/rc" 2> /dev/null || echo 0)"
""",
}

ESP_FILES = {
    "README": b"# ROCKNIX ABL\n",
    "backup_abl.sh": b"#!/system/bin/sh\necho backup\n",
    "flash_abl.sh": b"#!/system/bin/sh\necho flash\n",
    "restore_backup_abl.sh": b"#!/system/bin/sh\necho restore\n",
}


class Box:
    def __init__(self, body=b"PAYLOAD" * 400, slot_size=8192):
        self.dir = tempfile.mkdtemp(prefix="abl.")
        self.esp = os.path.join(self.dir, "esp")
        self.state = os.path.join(self.dir, "state")
        self.run = os.path.join(self.dir, "run")
        self.root = os.path.join(self.dir, "payload")
        self.stubs = os.path.join(self.dir, "stubs")
        self.bin = os.path.join(self.dir, "bin")
        self.calls = os.path.join(self.dir, "calls.log")
        self.dt = os.path.join(self.dir, "dt")
        self.cmdline = os.path.join(self.dir, "cmdline")
        self.bootid = os.path.join(self.dir, "bootid")
        self.power = os.path.join(self.dir, "power")
        for directory in (self.esp, self.state, self.run, self.root, self.stubs, self.bin, self.dt, self.power):
            os.makedirs(directory)
        self.deploy = "a" * 64 + ".0"
        write(os.path.join(self.dt, "compatible"),
              b"ayaneo,pocket-micro2\0qcom,sm8250\0ayaneo,pocket-micro\0")
        write(self.cmdline, f"quiet microos.deploy={self.deploy}\n")
        write(self.bootid, "0123456789abcdef\n")
        write(os.path.join(self.state, "confirmed"), self.deploy + "\n")
        self.disk_guid = "11111111-2222-3333-4444-555555555555"
        self.guid_a = "aaaaaaaa-2222-3333-4444-555555555555"
        self.guid_b = "bbbbbbbb-2222-3333-4444-555555555555"
        self.slot_size = slot_size
        self.slots = {}
        for key in ("a", "b"):
            self.slots[key] = os.path.join(self.dir, "slot-" + key)
        self.payload = self.build_payload(body)
        self.target = {
            "data": self.payload["data"], "length": self.payload["length"],
            "sha256": sha(self.payload["data"][:self.payload["length"]]),
        }
        self.older_data, self.older_length = make_elf(b"OLD" * 1200)
        self.older_ident = (self.older_length, sha(self.older_data[:self.older_length]))
        self.newer_data, self.newer_length = make_elf(b"NEW" * 700)
        self.newer_ident = (self.newer_length, sha(self.newer_data[:self.newer_length]))
        self.set_catalog()
        self.slot(self.slots["b"], self.payload["data"], self.target["sha256"])
        self.slot(self.slots["a"], self.older_data, "")
        write(os.path.join(self.power, "ac", "type"), "Mains\n")
        write(os.path.join(self.power, "ac", "online"), "1\n")
        self.write_stubs()

    def close(self):
        shutil.rmtree(self.dir, ignore_errors=True)

    def build_payload(self, body):
        os.makedirs(os.path.join(self.root, "esp"))
        data, length = make_elf(body)
        digest = sha(data)
        write(os.path.join(self.root, "abl_signed-SM8250.elf"), data)
        write(os.path.join(self.root, "abl_signed-SM8250.elf.sha256"),
              f"{digest}  abl_signed-SM8250.elf\n".encode())
        write(os.path.join(self.root, "manifest"),
              f"MICROOS_ABL_FORMAT=1\nMICROOS_ABL_VERSION=9.9\nMICROOS_ABL_SOC=SM8250\n"
              f"MICROOS_ABL_LENGTH={length}\nMICROOS_ABL_SHA256={digest}\n"
              f"MICROOS_ABL_ADMITTED={digest}\n".encode())
        for name, content in ESP_FILES.items():
            write(os.path.join(self.root, "esp", name), content, 0o755 if name.endswith(".sh") else 0o644)
        return {"data": data, "length": length, "whole": digest}

    def add_tail(self, size=16):
        path = os.path.join(self.root, "abl_signed-SM8250.elf")
        with open(path, "rb") as f:
            data = f.read() + b"\0" * size
        write(path, data)
        whole = sha(data)
        lines = []
        with open(os.path.join(self.root, "manifest")) as f:
            for line in f.read().splitlines():
                key = line.split("=", 1)[0]
                if key in ("MICROOS_ABL_SHA256", "MICROOS_ABL_ADMITTED"):
                    line = f"{key}={whole}"
                lines.append(line)
        write(os.path.join(self.root, "manifest"), "\n".join(lines) + "\n")
        self.payload["data"] = data
        self.payload["whole"] = whole
        self.target["data"] = data
        self.target["sha256"] = whole

    def set_catalog(self):
        rows = HEADER
        rows += catalog_row(1, "1.2", self.older_length, self.older_ident[1])
        rows += catalog_row(2, "9.9", self.payload["length"], self.target["sha256"])
        write(os.path.join(self.root, "releases.tsv"), rows)

    def add_newer_row(self):
        rows = HEADER
        rows += catalog_row(1, "1.2", self.older_length, self.older_ident[1])
        rows += catalog_row(2, "9.9", self.payload["length"], self.target["sha256"])
        rows += catalog_row(3, "10.0", self.newer_length, self.newer_ident[1])
        write(os.path.join(self.root, "releases.tsv"), rows)

    def slot(self, path, data, ident_digest):
        payload = data + bytes([0xff]) * (self.slot_size - len(data))
        payload = payload[:self.slot_size]
        write(path, payload)
        return payload

    def read_slot(self, key):
        with open(self.slots[key], "rb") as f:
            return f.read()

    def write_stubs(self):
        self.programs = {}
        for name, text in STUBS.items():
            path = os.path.join(self.bin, name)
            write(path, text, 0o755)
            self.programs[name] = path

    def env(self):
        return {
            "MICROOS_ESP": self.esp,
            "MICROOS_RUNDIR": self.run,
            "MICROOS_STATEDIR": self.state,
            "MICROOS_BOOTIMG_UPDATE": self.programs["bootimg-update"],
            "MICROOS_SYSTEMD_INHIBIT": self.programs["systemd-inhibit"],
            "MICROOS_DT": self.dt,
            "MICROOS_POWER_SUPPLY": self.power,
            "MICROOS_CMDLINE": self.cmdline,
            "MICROOS_BOOTID": self.bootid,
            "MICROOS_ABL_ROOT": self.root,
            "MICROOS_ABL_CATALOG": os.path.join(self.root, "releases.tsv"),
            "MICROOS_ABL_A": self.slots["a"],
            "MICROOS_ABL_B": self.slots["b"],
            "MICROOS_ABL_ACTIVE": "a",
            "MICROOS_ABL_DISK_GUID": self.disk_guid,
            "MICROOS_ABL_PART_GUID_A": self.guid_a,
            "MICROOS_ABL_PART_GUID_B": self.guid_b,
            "CALLS": self.calls,
            "STUB_DIR": self.stubs,
        }

    def calls_text(self):
        try:
            with open(self.calls) as f:
                return f.read()
        except OSError:
            return ""

    def calls_matching(self, prefix):
        return [line for line in self.calls_text().splitlines() if line.startswith(prefix)]

    def clear_calls(self):
        try:
            os.unlink(self.calls)
        except OSError:
            pass

    def backup_dir(self):
        return os.path.join(self.esp, "rocknix_abl", "SM8250", "microos-backup")

    def journal_file(self):
        return os.path.join(self.state, "abl", "journal.json")

    def set_journal(self, values):
        write(self.journal_file(), json.dumps(values) + "\n")

    def get_journal(self):
        with open(self.journal_file()) as f:
            return json.load(f)


def full_env(box, extra=None):
    env = dict(os.environ)
    for key in ("MICROOS_ABL_SCAN",):
        env.pop(key, None)
    env.update(box.env())
    env["MICROOS_ABL_INHIBITED"] = "1"
    if extra:
        for key, value in extra.items():
            if value is None:
                env.pop(key, None)
            else:
                env[key] = value
    return env


def run_tool(box, args, extra=None, timeout=60):
    p = subprocess.run([sys.executable, TOOL, *args], env=full_env(box, extra),
                       capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr


def result_of(out):
    lines = [line[len("microos-abl: "):] for line in out.splitlines() if line.startswith("microos-abl: ")]
    return lines[-1] if lines else ""


def load_module(env):
    saved = dict(os.environ)
    os.environ.clear()
    os.environ.update(env)
    try:
        loader = importlib.machinery.SourceFileLoader("microos_abl_case", TOOL)
        mod = importlib.util.module_from_spec(importlib.util.spec_from_loader("microos_abl_case", loader))
        loader.exec_module(mod)
        return mod
    finally:
        os.environ.clear()
        os.environ.update(saved)


def run_module(box, args, patch=None, extra=None):
    env = full_env(box, extra)
    out = io.StringIO()
    err = io.StringIO()
    saved_handlers = {}
    for sig in (signal.SIGTERM, signal.SIGINT, signal.SIGHUP):
        saved_handlers[sig] = signal.getsignal(sig)
    saved_env = dict(os.environ)
    saved_argv = list(sys.argv)
    os.environ.clear()
    os.environ.update(env)
    sys.argv = [TOOL] + [str(a) for a in args]
    try:
        mod = load_module(env)
        mod.lock_memory = lambda: None
        if patch:
            patch(mod)
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = mod.main(list(args))
    finally:
        os.environ.clear()
        os.environ.update(saved_env)
        sys.argv = saved_argv
        for sig, handler in saved_handlers.items():
            signal.signal(sig, handler)
    return rc, out.getvalue(), err.getvalue()


def slot_reads(mod, plan, seen=None):
    original = mod.read_slot
    counts = {}

    def reader(slot):
        path = slot["path"]
        index = counts.get(path, 0)
        counts[path] = index + 1
        if seen is not None:
            seen.append(path)
        data = original(slot)
        action = plan.get(os.path.basename(path), {}).get(index)
        if action == "flip":
            data = bytes([data[0] ^ 0xFF]) + data[1:]
        elif action == "short":
            data = data[:-1]
        return data

    mod.read_slot = reader
    return counts


def patch_bootimg(box, rc):
    write(os.path.join(box.stubs, "bootimg", "rc"), f"{rc}\n")


def check_esp_backup_absent(box):
    need(not os.path.exists(box.backup_dir()), "a backup was written")


def do(box, args, extra=None):
    code, out, err = run_tool(box, args, extra)
    return code, result_of(out), out, err


def confirm_of(box):
    return box.target["sha256"]


@case
def catalog_malformed():
    box = Box()
    try:
        write(os.path.join(box.root, "releases.tsv"), "order\tversion\tsoc\tlength\tsha\n")
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: payload", f"result {result}")
        need(code == 1, f"exit {code}")
    finally:
        box.close()


@case
def catalog_duplicate_order():
    box = Box()
    try:
        rows = HEADER + catalog_row(1, "1.2", box.older_length, box.older_ident[1])
        rows += catalog_row(1, "9.9", box.payload["length"], box.target["sha256"])
        write(os.path.join(box.root, "releases.tsv"), rows)
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: payload", f"result {result}")
    finally:
        box.close()


@case
def catalog_duplicate_ident():
    box = Box()
    try:
        rows = HEADER + catalog_row(1, "1.2", box.payload["length"], box.target["sha256"])
        rows += catalog_row(2, "9.9", box.payload["length"], box.target["sha256"])
        write(os.path.join(box.root, "releases.tsv"), rows)
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: payload", f"result {result}")
    finally:
        box.close()


@case
def identify_stale_tail_and_offsets():
    box = Box()
    try:
        code, result, out, err = do(box, ["status"])
        need("slot a 1.2" in out, f"stale tail slot a: {out}")
        need("slot b 9.9" in out, f"target slot b: {out}")
        box.slot(box.slots["a"], b"\0\0\0\0" + box.older_data, "")
        code, result, out, err = do(box, ["status"])
        need("slot a unknown" in out, f"prefixed bytes identified: {out}")
    finally:
        box.close()


@case
def identify_extent_variants():
    box = Box()
    try:
        plain, plain_length = make_elf(b"SEC" * 500, sections=0)
        write(os.path.join(box.root, "releases.tsv"),
              HEADER + catalog_row(1, "1.2", plain_length, sha(plain[:plain_length])))
        write(os.path.join(box.root, "abl_signed-SM8250.elf"), plain)
        write(os.path.join(box.root, "manifest"),
              f"MICROOS_ABL_FORMAT=1\nMICROOS_ABL_VERSION=1.2\nMICROOS_ABL_SOC=SM8250\n"
              f"MICROOS_ABL_LENGTH={plain_length}\nMICROOS_ABL_SHA256={sha(plain)}\n"
              f"MICROOS_ABL_ADMITTED={sha(plain)}\n")
        box.target = {"data": plain, "length": plain_length, "sha256": sha(plain[:plain_length])}
        box.slot(box.slots["a"], plain, "")
        box.slot(box.slots["b"], plain, "")
        code, result, out, err = do(box, ["status"])
        need(result == "current", f"no section headers: {result} {out}")
        over, _ = make_elf(b"PAST" * 100, claim=1 << 20)
        box.slot(box.slots["a"], over, "")
        code, result, out, err = do(box, ["status"])
        need("slot a unknown" in out, f"extent past the slot: {out}")
    finally:
        box.close()


@case
def payload_mismatches():
    box = Box()
    try:
        with open(manifest_of(box)) as f:
            text = f.read()
        write(manifest_of(box), text.replace("MICROOS_ABL_SHA256=", "MICROOS_ABL_SHA256=0"))
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: payload", f"elf differs from manifest: {result}")
        box.close()
        box = Box()
        write(manifest_of(box), manifest_text(box).replace("MICROOS_ABL_ADMITTED=", "MICROOS_ABL_ADMITTED=0"))
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: payload", f"admitted differs: {result}")
        box.close()
        box = Box()
        rows = HEADER + catalog_row(1, "1.2", box.older_length, box.older_ident[1])
        write(os.path.join(box.root, "releases.tsv"), rows)
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: payload", f"row missing: {result}")
    finally:
        box.close()


def manifest_of(box):
    return os.path.join(box.root, "manifest")


def manifest_text(box):
    with open(manifest_of(box)) as f:
        return f.read()


@case
def payload_confirmed():
    box = Box()
    try:
        os.unlink(os.path.join(box.state, "confirmed"))
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: not confirmed", f"confirmed missing: {result}")
        need(code == 1, f"confirmed missing: exit {code}")
        write(os.path.join(box.state, "confirmed"), "b" * 64 + ".0\n")
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: not confirmed", f"confirmed differs: {result}")
        need(code == 1, f"confirmed differs: exit {code}")
        check_esp_backup_absent(box)
    finally:
        box.close()


@case
def overrides_mode():
    box = Box()
    try:
        code, out, err = run_tool(box, ["update", confirm_of(box)], {
            "MICROOS_ABL_CATALOG": "", "MICROOS_ABL_A": "", "MICROOS_ABL_B": "",
            "MICROOS_ABL_ACTIVE": "", "MICROOS_ABL_DISK_GUID": "",
            "MICROOS_ABL_PART_GUID_A": "", "MICROOS_ABL_PART_GUID_B": ""})
        need(result_of(out) == "refused: mode", f"one override alone: {result_of(out)}")
        device = "/dev/loop0" if os.path.exists("/dev/loop0") else "/dev/null"
        code, out, err = run_tool(box, ["update", confirm_of(box)], {"MICROOS_ABL_A": device})
        need(result_of(out) == "refused: mode", f"block device in testing mode: {result_of(out)}")
        code, out, err = run_tool(box, ["update", confirm_of(box)], {
            "MICROOS_ABL_SCAN": "/dev/null", "MICROOS_ABL_CATALOG": ""})
        need(result_of(out) == "refused: mode", f"loop scan with a non loop device: {result_of(out)}")
    finally:
        box.close()


@case
def equal_is_current():
    box = Box()
    try:
        box.slot(box.slots["a"], box.payload["data"], "")
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "current", f"result {result}")
        need(code == 0, f"exit {code}")
        need(not os.path.exists(box.journal_file()), "a journal was written")
        check_esp_backup_absent(box)
    finally:
        box.close()


@case
def newer_is_refused():
    box = Box()
    try:
        box.add_newer_row()
        box.slot(box.slots["b"], box.newer_data, "")
        box.slot(box.slots["a"], box.payload["data"], "")
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: newer", f"result {result}")
        need(code == 1, f"exit {code}")
    finally:
        box.close()


@case
def unknown_is_refused():
    box = Box()
    try:
        write(box.slots["a"], b"NOTELF" + b"\0" * (box.slot_size - 6))
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: unrecognized", f"result {result}")
        need(code == 1, f"exit {code}")
    finally:
        box.close()


@case
def update_writes():
    box = Box()
    try:
        code, result, out, err = do(box, ["update", confirm_of(box)], {"MICROOS_ABL_INHIBITED": None})
        need(result == "updated 9.9", f"result {result} {err}")
        need(code == 0, f"exit {code}")
        data = box.read_slot("a")
        need(data[:box.payload["length"]] == box.payload["data"][:box.payload["length"]],
             "slot a does not hold the payload")
        lines = box.calls_matching("inhibit ")
        need(lines, f"the inhibitor stub was not called: {box.calls_text()}")
        need("--what=sleep --mode=block --who=microos-abl" in lines[0], f"inhibitor options: {lines[0]}")
        need(box.get_journal()["order"] == ["b", "a"], f"write order {box.get_journal()['order']}")
    finally:
        box.close()


@case
def power_gate():
    box = Box()
    try:
        os.unlink(os.path.join(box.power, "ac", "online"))
        write(os.path.join(box.power, "ac", "online"), "0\n")
        write(os.path.join(box.power, "bat", "type"), "Battery\n")
        write(os.path.join(box.power, "bat", "present"), "1\n")
        write(os.path.join(box.power, "bat", "capacity"), "10\n")
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "skipped: power", f"below 20: {result}")
        need(code == 3, f"below 20: exit {code}")
        write(os.path.join(box.power, "bat", "capacity"), "50\n")
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "updated 9.9", f"battery 50: {result}")
        box.close()
        box = Box()
        shutil.rmtree(box.power)
        os.makedirs(box.power)
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "skipped: power", f"no supply: {result}")
        box.close()
        box = Box()
        write(os.path.join(box.power, "ac", "online"), "1\n")
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "updated 9.9", f"AC online: {result}")
    finally:
        box.close()


@case
def lock_gates():
    box = Box()
    try:
        os.makedirs(box.run, exist_ok=True)
        fd = os.open(os.path.join(box.run, "abl.lock"), os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "skipped: busy", f"abl.lock busy: {result}")
        need(code == 3, f"abl.lock busy: exit {code}")
        code, result, out, err = do(box, ["status"])
        need(result == "skipped: busy", f"status under a busy abl.lock: {result}")
        need(code == 3, f"status under a busy abl.lock: exit {code}")
        os.close(fd)
        box.close()
        box = Box()
        fd = os.open(os.path.join(box.run, "bootimg.lock"), os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)

        def jump(mod):
            state = {"n": 0}

            def clock():
                state["n"] += 1
                if state["n"] == 1:
                    return 0.0
                return 100.0 + (state["n"] - 2) * 10.0

            mod.boottime = clock

        code, out, err = run_module(box, ["update", confirm_of(box)], jump)
        need(result_of(out) == "skipped: esp busy", f"bootimg.lock busy: {result_of(out)}")
        need(code == 3, f"bootimg.lock busy: exit {code}")
        check_esp_backup_absent(box)
        os.close(fd)
    finally:
        box.close()


@case
def esp_gate_and_sync():
    box = Box()
    try:
        patch_bootimg(box, 1)
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "skipped: esp", f"check rc 1: {result}")
        need(code == 3, f"check rc 1: exit {code}")
        check_esp_backup_absent(box)
        patch_bootimg(box, 0)
        stale = os.path.join(box.esp, "rocknix_abl", "SM8250", "flash_abl.sh")
        write(stale, b"stale\n")
        seen = []

        def before_write(mod):
            original = mod.write_slot

            def writer(slot, data):
                if not seen:
                    with open(stale, "rb") as f:
                        seen.append(f.read())
                return original(slot, data)

            mod.write_slot = writer

        code, out, err = run_module(box, ["update", confirm_of(box)], before_write)
        need(result_of(out) == "updated 9.9", f"sync run: {result_of(out)} {err}")
        need(seen == [ESP_FILES["flash_abl.sh"]], f"the folder was not refreshed before the write: {seen}")
        need(stat.S_IMODE(os.stat(stale).st_mode) == 0o755, "the script mode")
        readme = os.path.join(box.esp, "rocknix_abl", "README")
        with open(readme, "rb") as f:
            need(f.read() == ESP_FILES["README"], "README not synced")
        write(stale, b"stale again\n")
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "current", f"current: {result} {err}")
        with open(stale, "rb") as f:
            need(f.read() == ESP_FILES["flash_abl.sh"], "the folder was not refreshed on the current path")
        os.unlink(readme)
        os.makedirs(readme)
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "skipped: esp", f"refresh failure on the current path: {result}")
        need(code == 3, f"refresh failure on the current path: exit {code}")
    finally:
        box.close()


@case
def backup_failures():
    box = Box()
    try:
        before = box.read_slot("a")
        code, out, err = run_module(box, ["update", confirm_of(box)],
                                    lambda mod: slot_reads(mod, {"slot-a": {2: "flip"}}))
        need(result_of(out) == "skipped: backup", f"unstable read: {result_of(out)}")
        need(box.read_slot("a") == before, "a slot was written after an unstable read")
        box.close()
        box = Box()

        def bad_readback(mod):
            original = mod.read_file_exact
            state = {"n": 0}

            def reader(path, size):
                state["n"] += 1
                data = original(path, size)
                if state["n"] == 1:
                    return data[:-1] + bytes([data[-1] ^ 0xFF])
                return data

            mod.read_file_exact = reader

        code, out, err = run_module(box, ["update", confirm_of(box)], bad_readback)
        need(result_of(out) == "skipped: backup", f"readback mismatch: {result_of(out)}")
        box.close()
        box = Box()
        code, out, err = run_module(box, ["update", confirm_of(box)],
                                    lambda mod: setattr(mod, "free_space", lambda p: 0))
        need(result_of(out) == "skipped: backup", f"ESP full: {result_of(out)}")
        box.close()
        box = Box()
        os.makedirs(os.path.join(box.state, "abl"), exist_ok=True)
        write(os.path.join(box.state, "abl", "backup"), b"not a dir\n")
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "skipped: backup", f"statedir copy fails: {result}")
        need(box.read_slot("a")[:64] == box.older_data[:64], "a slot was written without a statedir copy")
        box.close()
        box = Box()
        os.makedirs(box.backup_dir(), exist_ok=True)
        name = "abl-" + sha(box.read_slot("a")) + ".img"
        write(os.path.join(box.backup_dir(), name), b"other content\n")
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: backup collision", f"collision: {result}")
    finally:
        box.close()


@case
def slot_changed_after_backup():
    box = Box()
    try:
        before = box.read_slot("a")
        code, out, err = run_module(box, ["update", confirm_of(box)],
                                    lambda mod: slot_reads(mod, {"slot-a": {3: "flip"}}))
        need(result_of(out) == "skipped: changed", f"result {result_of(out)}")
        need(box.read_slot("a") == before, "the slot was written")
    finally:
        box.close()


@case
def inactive_slot_first():
    box = Box()
    try:
        box.slot(box.slots["a"], box.older_data, "")
        box.slot(box.slots["b"], box.older_data, "")
        writes = []

        def patch(mod):
            original = mod.write_slot

            def writer(slot, data):
                writes.append(os.path.basename(slot["path"]))
                return original(slot, data)

            mod.write_slot = writer

        code, out, err = run_module(box, ["update", confirm_of(box)], patch)
        need(result_of(out) == "updated 9.9", f"result {result_of(out)}")
        need(writes == ["slot-b", "slot-a"], f"write order {writes}")
        need(box.get_journal()["order"] == ["b", "a"], f"journal order {box.get_journal()['order']}")
    finally:
        box.close()


@case
def active_undetermined():
    box = Box()
    try:
        code, out, err = run_tool(box, ["update", confirm_of(box)], {"MICROOS_ABL_ACTIVE": "none"})
        need(result_of(out) == "refused: slot", f"result {result_of(out)}")
    finally:
        box.close()


@case
def inactive_write_failure():
    box = Box()
    try:
        box.slot(box.slots["a"], box.older_data, "")
        box.slot(box.slots["b"], box.older_data, "")
        before_a = box.read_slot("a")
        before_b = box.read_slot("b")

        def patch(mod):
            original = mod.write_slot
            seen = {"n": 0}

            def writer(slot, data):
                if os.path.basename(slot["path"]) == "slot-b":
                    seen["n"] += 1
                    if seen["n"] == 1:
                        raise OSError(5, "injected")
                return original(slot, data)

            mod.write_slot = writer

        code, out, err = run_module(box, ["update", confirm_of(box)], patch)
        need(result_of(out) == "failed-b-restored", f"result {result_of(out)}")
        need(code == 1, f"exit {code}")
        need(box.read_slot("b") == before_b, "abl_b was not restored")
        need(box.read_slot("a") == before_a, "abl_a was touched")
        journal = box.get_journal()
        need(journal["phase"] == "failed-b-restored", f"phase {journal['phase']}")
        need("written" not in journal or "b" not in journal["written"], f"written {journal.get('written')}")
        box.close()
        box = Box()
        box.slot(box.slots["a"], box.older_data, "")
        box.slot(box.slots["b"], box.older_data, "")

        def nowhere(mod):
            original = mod.write_slot

            def writer(slot, data):
                if os.path.basename(slot["path"]) == "slot-b":
                    raise OSError(5, "injected")
                return original(slot, data)

            mod.write_slot = writer

        code, out, err = run_module(box, ["update", confirm_of(box)], nowhere)
        need(result_of(out) == "failed-b-unrestored", f"result {result_of(out)}")
        need(box.get_journal()["phase"] == "failed-b-unrestored", f"phase {box.get_journal()['phase']}")
    finally:
        box.close()


@case
def active_write_failure():
    box = Box()
    try:
        box.slot(box.slots["a"], box.older_data, "")
        box.slot(box.slots["b"], box.older_data, "")
        before_b = box.read_slot("b")

        def patch(mod):
            original = mod.write_slot
            seen = {"n": 0}

            def writer(slot, data):
                if os.path.basename(slot["path"]) == "slot-a":
                    seen["n"] += 1
                    if seen["n"] == 1:
                        raise OSError(5, "injected")
                return original(slot, data)

            mod.write_slot = writer

        code, out, err = run_module(box, ["update", confirm_of(box)], patch)
        need(result_of(out) == "failed-a-restored", f"result {result_of(out)}")
        need(box.read_slot("b") != before_b, "the inactive slot was not written")
        need(box.get_journal()["phase"] == "failed-a-restored", f"phase {box.get_journal()['phase']}")
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: failed before", f"rerun after a failed active write: {result}")
        need(code == 1, f"rerun after a failed active write: exit {code}")
        entry = box.get_journal()["original"]["a"]
        image = os.path.join(box.backup_dir(), entry["name"])
        code, result, out, err = do(box, ["restore", "a", image])
        need(result.startswith("restored a "), f"restore of the failed slot: {result} {err}")
        need(box.get_journal()["phase"] == "restored-a", f"phase {box.get_journal()['phase']}")
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "updated 9.9", f"after the restore: {result} {err}")
    finally:
        box.close()


@case
def signals():
    def during(signum):
        def patch(mod):
            original = mod.write_slot
            seen = {"n": 0}

            def writer(slot, data):
                got = original(slot, data)
                if os.path.basename(slot["path"]) == "slot-b" and not seen["n"]:
                    seen["n"] = 1
                    os.kill(os.getpid(), signum)
                return got

            mod.write_slot = writer

        return patch

    for signum in (signal.SIGTERM, signal.SIGHUP, signal.SIGINT):
        box = Box()
        try:
            box.slot(box.slots["a"], box.older_data, "")
            box.slot(box.slots["b"], box.older_data, "")
            before_a = box.read_slot("a")
            code, out, err = run_module(box, ["update", confirm_of(box)], during(signum))
            need(result_of(out) == "skipped: signal", f"signal {signum} during the write: {result_of(out)}")
            need(code == 3, f"signal {signum}: exit {code}")
            need(box.read_slot("b")[:64] == box.payload["data"][:64],
                 f"signal {signum}: the inactive write did not land")
            need(box.read_slot("a") == before_a, f"signal {signum}: the active slot was written")
        finally:
            box.close()
    box = Box()
    try:
        before = box.read_slot("a")

        def before_write(mod):
            original = mod.begin_window

            def window():
                original()
                os.kill(os.getpid(), signal.SIGTERM)

            mod.begin_window = window

        code, out, err = run_module(box, ["update", confirm_of(box)], before_write)
        need(result_of(out) == "skipped: signal", f"signal before the write: {result_of(out)}")
        need(box.read_slot("a") == before, "a slot was written after the signal")
    finally:
        box.close()


def failed_inactive_unrestored(box):
    box.slot(box.slots["a"], box.older_data, "")
    box.slot(box.slots["b"], box.older_data, "")

    def patch(mod):
        original = mod.write_slot

        def writer(slot, data):
            if os.path.basename(slot["path"]) == "slot-b":
                seen = getattr(writer, "seen", 0)
                writer.seen = seen + 1
                if seen == 0:
                    original(slot, data[:512])
                raise OSError(5, "injected")
            return original(slot, data)

        mod.write_slot = writer

    code, out, err = run_module(box, ["update", confirm_of(box)], patch)
    need(result_of(out) == "failed-b-unrestored", f"setup result {result_of(out)}")


def resume_box():
    box = Box()
    failed_inactive_unrestored(box)
    return box


@case
def resume_candidate():
    box = resume_box()
    try:
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "updated 9.9", f"result {result} {err}")
        need(box.read_slot("b")[:512] == box.payload["data"][:512], "abl_b was not resumed")
        journal = box.get_journal()
        need(journal["phase"] == "done", f"phase {journal['phase']}")
        need("b" in journal.get("evidence", {}), "no evidence backup for abl_b")
        need(journal["original"]["b"] != journal["evidence"]["b"], "evidence replaced original")
    finally:
        box.close()


@case
def resume_refusals():
    box = resume_box()
    try:
        journal = box.get_journal()
        journal["target"]["sha256"] = "0" * 64
        box.set_journal(journal)
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: unrecognized", f"other target: {result}")
    finally:
        box.close()
    box = resume_box()
    try:
        journal = box.get_journal()
        journal["disk_guid"] = "99999999-2222-3333-4444-555555555555"
        box.set_journal(journal)
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: unrecognized", f"other disk: {result}")
    finally:
        box.close()
    box = resume_box()
    try:
        journal = box.get_journal()
        name = journal["original"]["b"]["name"]
        os.unlink(os.path.join(box.backup_dir(), name))
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "updated 9.9", f"statedir copy only: {result}")
    finally:
        box.close()
    box = resume_box()
    try:
        journal = box.get_journal()
        name = journal["original"]["b"]["name"]
        os.unlink(os.path.join(box.backup_dir(), name))
        os.unlink(os.path.join(box.state, "abl", "backup", name))
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: unrecognized", f"both copies gone: {result}")
    finally:
        box.close()
    box = resume_box()
    try:
        journal = box.get_journal()
        name = journal["original"]["b"]["name"]
        for directory in (box.backup_dir(), os.path.join(box.state, "abl", "backup")):
            path = os.path.join(directory, name)
            with open(path, "rb") as f:
                data = bytearray(f.read())
            data[0] ^= 0xFF
            write(path, bytes(data))
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: unrecognized", f"edited backups: {result}")
    finally:
        box.close()
    box = resume_box()
    try:
        with open(box.slots["b"], "rb") as f:
            data = bytearray(f.read())
        data[4096:4608] = b"\x55" * 512
        write(box.slots["b"], bytes(data))
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: unrecognized", f"a sector matching neither: {result}")
    finally:
        box.close()


def fake_gpt(disk, parts):
    entries = [None]
    for label, attrs in parts:
        entries.append({"label": label, "guid": label + "-guid", "first": 0, "last": 0, "attrs": attrs})
    return {"disk_guid": disk, "sector": 4096, "parts": entries}


def default_parts(abl_a=True, abl_b=True, boot_a=4, boot_b=0):
    parts = [("boot_a", boot_a), ("boot_b", boot_b)]
    if abl_a:
        parts.append(("abl_a", 0))
    if abl_b:
        parts.append(("abl_b", 0))
    return parts


def partition_refusal(box, length, tables, sizes=None, removable=False, sysfs=None, devices=("/dev/sda",)):
    sizes = sizes or {}

    def patch(mod):
        mod.read_gpt = lambda dev: tables.get(dev)
        mod.block_size = lambda path: sizes.get(os.path.basename(path), 1 << 20)
        mod.sector_size = lambda path: 4096
        mod.block_removable = lambda dev: removable
        mod.block_sysfs = lambda dev: sysfs or "/sys/devices/platform/soc/1d84000.ufshc/block/sda"
        mod.block_name = lambda dev: dev.rsplit("/", 1)[-1]
        mod.boot_lun = lambda: ""
        mod.cmdline_suffix = lambda: ""

    state = {"result": ""}

    def capture(mod):
        patch(mod)
        try:
            mod.probe_partitions({"name": "production", "devices": list(devices)}, length)
        except mod.Refused as err:
            state["result"] = err.result
        return state

    code, out, err = run_module(box, ["status"], capture)
    return state["result"]


@case
def partition_gates():
    box = Box()
    try:
        length = box.payload["length"]
        sda = "/dev/sda"
        good = {sda: fake_gpt("disk-a", default_parts())}
        need(partition_refusal(box, length, good) == "", "the good GPT was refused")
        need(partition_refusal(box, length, {sda: fake_gpt("disk-a", default_parts(abl_b=False))})
             == "refused: partitions", "missing abl_b")
        dup = default_parts()
        dup.append(("abl_a", 0))
        need(partition_refusal(box, length, {sda: fake_gpt("disk-a", dup)}) == "refused: partitions",
             "duplicate label")
        two = {sda: fake_gpt("disk-a", default_parts(abl_b=False)),
               "/dev/sdb": fake_gpt("disk-b", [("abl_b", 0)])}
        need(partition_refusal(box, length, two, devices=("/dev/sda", "/dev/sdb")) == "refused: partitions",
             "different disks")
        need(partition_refusal(box, length, good, removable=True) == "refused: partitions", "removable")
        need(partition_refusal(box, length, {"/dev/mmcblk0": fake_gpt("disk-a", default_parts())},
                               devices=("/dev/mmcblk0",)) == "refused: partitions", "mmcblk")
        need(partition_refusal(box, length, good, sizes={"sda4": 9 << 20}) == "refused: partitions",
             "slot over 8 MiB")
        need(partition_refusal(box, length + (2 << 20), good, sizes={"sda4": 1 << 20})
             == "refused: partitions", "payload larger than the slot")
        need(partition_refusal(box, length, {sda: fake_gpt("disk-a", default_parts(boot_a=0, boot_b=0))})
             == "refused: slot", "no active slot")
        need(partition_refusal(box, length, {sda: fake_gpt("disk-a", default_parts(boot_a=0, boot_b=8))})
             == "", "boot_b alone is active b")
        need(partition_refusal(box, length, {sda: fake_gpt("disk-a", default_parts(boot_a=0, boot_b=0))})
             == "refused: slot", "neither bit set")
        need(partition_refusal(box, length, {sda: fake_gpt("disk-a", default_parts(boot_a=0, boot_b=0))})
             == "refused: slot", "neither bit set")
        need(partition_refusal(box, length, {sda: fake_gpt("disk-a", default_parts(boot_a=4, boot_b=8))})
             == "", "the PM2 GPT with both bits set was refused")

        def cross(mod):
            mod.read_gpt = lambda dev: good.get(dev)
            mod.block_size = lambda path: 1 << 20
            mod.sector_size = lambda path: 4096
            mod.block_removable = lambda dev: False
            mod.block_sysfs = lambda dev: "/sys/devices/platform/soc/1d84000.ufshc/block/sda"
            mod.block_name = lambda dev: dev.rsplit("/", 1)[-1]
            mod.boot_lun = lambda: "b"

        state = {"result": ""}

        def capture(mod):
            cross(mod)
            try:
                mod.probe_partitions({"name": "production", "devices": [sda]}, length)
            except mod.Refused as err:
                state["result"] = err.result

        run_module(box, ["status"], capture)
        need(state["result"] == "refused: slot", f"boot_lun disagrees: {state['result']}")
    finally:
        box.close()


@case
def interleaved_installs():
    box = Box()
    try:
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "updated 9.9", f"first install: {result}")
        other = os.path.join(box.dir, "state2")
        os.makedirs(other)
        write(os.path.join(other, "confirmed"), box.deploy + "\n")
        extra = {"MICROOS_STATEDIR": other}
        code, out, err = run_tool(box, ["update", confirm_of(box)], extra)
        need(result_of(out) == "current", f"the other install reads {result_of(out)}")
        journal = box.get_journal()
        image = os.path.join(box.backup_dir(), journal["original"]["a"]["name"])
        with open(image, "rb") as f:
            original = f.read()
        write(box.slots["a"], box.payload["data"][:512] + original[512:])
        code, out, err = run_tool(box, ["update", confirm_of(box)], extra)
        need(result_of(out) == "refused: unrecognized", f"torn slot from the other install: {result_of(out)}")
    finally:
        box.close()


@case
def restore_backup():
    box = Box()
    try:
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "updated 9.9", f"setup: {result}")
        journal = box.get_journal()
        name = journal["original"]["a"]["name"]
        image = os.path.join(box.backup_dir(), name)
        write(box.slots["a"], b"\x00" * box.slot_size)
        code, result, out, err = do(box, ["restore", "a", image])
        need(result.startswith("restored a "), f"restore: {result} {err}")
        with open(image, "rb") as f:
            need(box.read_slot("a") == f.read(), "the slot does not hold the backup")
        other = os.path.join(box.backup_dir(), journal["original"]["b"]["name"])
        need(sha(open(other, "rb").read()) != sha(open(image, "rb").read()), "the originals are equal")
        write(box.slots["a"], b"\x00" * box.slot_size)
        code, result, out, err = do(box, ["restore", "a", other])
        need(result == "refused: backup", f"a backup recorded for the other slot: {result}")
        need(box.read_slot("a") == b"\x00" * box.slot_size, "the slot was written")
        junk = os.path.join(box.dir, "junk.img")
        write(junk, b"\x00" * box.slot_size)
        code, result, out, err = do(box, ["restore", "a", junk])
        need(result == "refused: backup", f"a backup the journal does not name: {result}")
        journal = box.get_journal()
        journal["disk_guid"] = "99999999-2222-3333-4444-555555555555"
        box.set_journal(journal)
        code, result, out, err = do(box, ["restore", "a", image])
        need(result == "refused: backup", f"another disk in the journal: {result}")
    finally:
        box.close()


@case
def status_not_a_pm2():
    box = Box()
    try:
        empty = os.path.join(box.dir, "empty-dt")
        os.makedirs(empty)
        code, out, err = run_tool(box, ["status"], {"MICROOS_DT": empty})
        need(code == 0, f"status exit {code}")
        need(result_of(out) == "refused: not a PM2", f"status: {result_of(out)}")
    finally:
        box.close()


@case
def confirm_gate():
    box = Box()
    try:
        box.add_tail()
        whole = confirm_of(box)
        with open(os.path.join(box.root, "abl_signed-SM8250.elf"), "rb") as f:
            data = f.read()
        ident = sha(data[:box.payload["length"]])
        need(ident != whole, "the fixture identity equals the whole-file hash")
        for arg in ("0" * 64, whole[:12], whole.upper(), ident):
            code, result, out, err = do(box, ["update", arg])
            need(result == "refused: confirm", f"{arg[:12]}: {result}")
            need(code == 1, f"{arg[:12]}: exit {code}")
            need(box.read_slot("a")[:64] == box.older_data[:64], f"{arg[:12]}: a slot was written")
            check_esp_backup_absent(box)
        calls = []

        def no_partitions(mod):
            def probe(mode, length):
                calls.append(length)
                raise mod.Refused("refused: partitions")

            mod.probe_partitions = probe

        code, out, err = run_module(box, ["update", "0" * 64], no_partitions)
        need(result_of(out) == "refused: confirm", f"a wrong hash reached the partitions: {result_of(out)}")
        need(not calls, "a partition was read before the confirmation")
        code, result, out, err = do(box, ["update"])
        need(code == 2, f"no argument: exit {code}")
        need(not box.calls_matching("bootimg"), f"the ESP was checked without a confirmation: {box.calls_text()}")
    finally:
        box.close()


@case
def unconfirmed_deployment():
    box = Box()
    try:
        os.unlink(os.path.join(box.state, "confirmed"))
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: not confirmed", f"update: {result}")
        need(code == 1, f"update: exit {code}")
        code, result, out, err = do(box, ["status"])
        need(code == 0, f"status: exit {code}")
        need("confirmed no" in out, f"status: {out}")
        need("microos-abl: eligible" in out, f"status verdict: {out}")
        write(os.path.join(box.state, "confirmed"), "b" * 64 + ".0\n")
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "refused: not confirmed", f"another deployment: {result}")
        check_esp_backup_absent(box)
    finally:
        box.close()


@case
def exit_codes():
    box = Box()
    try:
        code, result, out, err = do(box, ["nonsense"])
        need(code == 2, f"unknown subcommand: exit {code}")
        need(not result, f"unknown subcommand: {result}")
        code, result, out, err = do(box, ["status", "a"])
        need(code == 2, f"status with an argument: exit {code}")
        os.makedirs(box.run, exist_ok=True)
        fd = os.open(os.path.join(box.run, "abl.lock"), os.O_RDWR | os.O_CREAT, 0o644)
        fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(code == 3, f"skipped busy: exit {code}")
        os.close(fd)
        code, result, out, err = do(box, ["update", "0" * 64])
        need(code == 1, f"refused confirm: exit {code}")
        box.slot(box.slots["a"], box.payload["data"], "")
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "current", f"current: {result}")
        need(code == 0, f"current: exit {code}")
    finally:
        box.close()


@case
def restore_power():
    box = Box()
    try:
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "updated 9.9", f"setup: {result}")
        image = os.path.join(box.backup_dir(), box.get_journal()["original"]["a"]["name"])
        before = box.read_slot("a")
        write(os.path.join(box.power, "ac", "online"), "0\n")
        write(os.path.join(box.power, "bat", "type"), "Battery\n")
        write(os.path.join(box.power, "bat", "present"), "1\n")
        write(os.path.join(box.power, "bat", "capacity"), "10\n")
        code, result, out, err = do(box, ["restore", "a", image])
        need(result == "skipped: power", f"restore on battery: {result}")
        need(code == 3, f"restore on battery: exit {code}")
        need(box.read_slot("a") == before, "the slot was written on battery")
        write(os.path.join(box.power, "bat", "capacity"), "80\n")
        code, result, out, err = do(box, ["restore", "a", image])
        need(result.startswith("restored a "), f"restore at 80 percent: {result} {err}")
    finally:
        box.close()


@case
def rerun_keeps_original():
    box = Box()
    try:
        box.slot(box.slots["a"], box.older_data, "")
        box.slot(box.slots["b"], box.older_data, "")
        before_b = box.read_slot("b")

        def patch(mod):
            original = mod.write_slot

            def writer(slot, data):
                got = original(slot, data)
                if os.path.basename(slot["path"]) == "slot-b":
                    os.kill(os.getpid(), signal.SIGHUP)
                return got

            mod.write_slot = writer

        code, out, err = run_module(box, ["update", confirm_of(box)], patch)
        need(result_of(out) == "skipped: signal", f"first run: {result_of(out)}")
        need(code == 3, f"first run: exit {code}")
        need(box.get_journal()["phase"] == "writing-b", f"phase {box.get_journal()['phase']}")
        code, result, out, err = do(box, ["update", confirm_of(box)])
        need(result == "updated 9.9", f"rerun: {result} {err}")
        journal = box.get_journal()
        need(journal["phase"] == "done", f"phase {journal['phase']}")
        entry = journal["original"]["b"]
        need(entry["sha256"] == sha(before_b), f"the carried original is {entry['sha256']}")
        image = os.path.join(box.backup_dir(), entry["name"])
        code, result, out, err = do(box, ["restore", "b", image])
        need(result.startswith("restored b "), f"restore after the rerun: {result} {err}")
        need(box.read_slot("b") == before_b, "abl_b does not hold its pre-update bytes")
    finally:
        box.close()


@case
def inhibit_missing():
    box = Box()
    try:
        reads = []

        def patch(mod):
            slot_reads(mod, {}, reads)

        code, out, err = run_module(box, ["update", confirm_of(box)], patch,
                                    {"MICROOS_ABL_INHIBITED": None,
                                     "MICROOS_SYSTEMD_INHIBIT": os.path.join(box.dir, "missing-inhibit")})
        need(result_of(out) == "skipped: inhibit", f"result {result_of(out)} {err}")
        need(code == 3, f"exit {code}")
        need(not reads, f"a slot was read: {reads}")
        check_esp_backup_absent(box)
        need(not os.path.exists(box.journal_file()), "a journal was written")
        code, out, err = run_module(box, ["restore", "a", os.path.join(box.dir, "missing.img")], None,
                                    {"MICROOS_ABL_INHIBITED": None,
                                     "MICROOS_SYSTEMD_INHIBIT": os.path.join(box.dir, "missing-inhibit")})
        need(result_of(out) == "skipped: inhibit", f"restore: {result_of(out)} {err}")
        need(code == 3, f"restore: exit {code}")
    finally:
        box.close()


def main():
    for fn in CASES:
        try:
            fn()
            print(f"PASS {fn.__name__}")
        except AssertionError as err:
            FAILED.append((fn.__name__, str(err)))
            print(f"FAIL {fn.__name__}: {err}")
        except Exception as err:
            FAILED.append((fn.__name__, repr(err)))
            print(f"ERROR {fn.__name__}: {err!r}")
    total = len(CASES) + (1 if LOOP else 0)
    if LOOP:
        try:
            p = subprocess.run(["bash", LOOP], capture_output=True, text=True, timeout=300)
            sys.stdout.write(p.stdout)
            sys.stderr.write(p.stderr)
            if p.returncode != 0:
                FAILED.append(("abl-loop", f"exit {p.returncode}"))
                print(f"FAIL abl-loop: exit {p.returncode}")
            else:
                print("PASS abl-loop")
        except (OSError, subprocess.SubprocessError) as err:
            FAILED.append(("abl-loop", repr(err)))
            print(f"ERROR abl-loop: {err!r}")
    print(f"abl: {total} cases, {len(FAILED)} failed")
    print(f"abl: {total} cases")
    return 1 if FAILED else 0


if __name__ == "__main__":
    sys.exit(main())
