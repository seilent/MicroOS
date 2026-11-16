#!/usr/bin/env bash
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
tree=${MICROOS_TREE:-$here/../system_files}
reap=$tree/usr/libexec/microos/microos-shm-reap
user=$tree/usr/lib/systemd/user
unit=$tree/usr/lib/systemd/system/microos-shm-reap@.service
rule=$tree/usr/share/polkit-1/rules.d/50-microos-shm-reap.rules
tmp=$(mktemp -d)
pid=""
wd=""
trap '[[ -z $pid ]] || kill "$pid" 2> /dev/null; [[ -z $wd ]] || kill "$wd" 2> /dev/null; exec 3>&- 2> /dev/null; rm -rf "$tmp"' EXIT
rc=0
fail() { echo "FAIL: $*" >&2; rc=1; }

[[ -x $reap ]] || fail "${reap#"$tree"} is not executable"
[[ $(id -u) == 0 ]] || { echo "shm-reap: needs root" >&2; exit 1; }

chmod 755 "$tmp"
shm=$tmp/shm
proc=$tmp/proc
cat > "$tmp/run.py" <<'EOF'
import ctypes
import os
import runpy
import sys

libc = ctypes.CDLL(None)
libc.setfsuid.argtypes = [ctypes.c_uint]
log = open(os.environ["HOOK_LOG"], "a")
swap = os.environ.get("SWAP", "")


def hook(event, args):
    global swap
    if event != "os.remove":
        return
    now = libc.setfsuid(-1)
    log.write(f"{os.path.basename(args[0])} {now}\n")
    log.flush()
    if swap and args[0].endswith("/" + swap):
        swap = ""
        libc.setfsuid(0)
        if os.path.isdir(os.environ["SWAP_SRC"]):
            os.unlink(args[0])
        os.rename(os.environ["SWAP_SRC"], args[0])
        libc.setfsuid(now)


sys.addaudithook(hook)
sys.argv = sys.argv[1:]
try:
    runpy.run_path(sys.argv[0], run_name="__main__")
finally:
    log.write(f"end {libc.setfsuid(-1)}\n")
EOF

reset() {
  rm -rf "$shm" "$proc" "$tmp/file" "$tmp/src"
  mkdir -p "$shm" "$proc"
  chmod 1777 "$shm"
  : > "$tmp/file"
  : > "$tmp/hook"
}
seg() {
  head -c "${4:-400660}" /dev/zero > "$shm/$1"
  chown "${3:-1000}:${3:-1000}" "$shm/$1"
  touch -d "@$(($(date +%s) - $2))" "$shm/$1"
}
entry() {
  mkdir -p "$1/fd"
  printf 'Name:\tx\nState:\t%s (x)\nUid:\t%s\t%s\t%s\t%s\n' "$3" "$2" "$2" "$2" "$2" > "$1/status"
  : > "$1/maps"
}
task() {
  entry "$proc/$1" "$2" "${3:-S}"
  entry "$proc/$1/task/$1" "$2" "${3:-S}"
}
fdhold() { ln -s "$shm/$3" "$proc/$1/fd/$2"; }
maphold() {
  local d
  d=$(stat -c '%Hd %Ld %i' "$shm/$2")
  set -- "$1" "$2" $d
  printf '7f0000000000-7f0000600000 rw-s 00000000 %02x:%02x %s /dev/shm/%s (deleted)\n' "$3" "$4" "$5" "$2" >> "$proc/$1/maps"
}
run() {
  r=0
  MICROOS_SHM_DIR=$shm MICROOS_PROC=$proc HOOK_LOG=$tmp/hook python3 "$tmp/run.py" "$reap" "${@:2}" > "$tmp/out" 2>&1 || r=$?
  ((r == ${want:-0})) || fail "$1: exit $r: $(cat "$tmp/out")"
}
left() { (cd "$shm" && ls -1 | sort | paste -sd,); }
logged() { grep -qF -- "$1" "$tmp/out"; }

reset
seg u1000-Shm_fd 120
seg u1000-Shm_maps 120
seg u1000-Shm_nd 120
seg u1000-Shm_zombie 120
seg u1000-Shm_old 120 1000 524304
seg u1000-Shm_new 5
seg u1001-Shm_prefix 120
seg Shm_bare 120
seg u1000-Shm_uid 120 1001
seg target 120
ln -s target "$shm/u1000-Shm_link"
chown -h 1000:1000 "$shm/u1000-Shm_link"
touch -h -d "@$(($(date +%s) - 120))" "$shm/u1000-Shm_link"
task 2 0
task 10 1000
fdhold 10 5 u1000-Shm_fd
ln -s "$tmp/file/x" "$proc/10/fd/6"
task 11 1000
maphold 11 u1000-Shm_maps
task 12 1001
fdhold 12 3 u1000-Shm_nd
chmod 000 "$proc/12/maps" "$proc/12/fd"
task 13 1000 Z
entry "$proc/13/task/14" 1000 Z
entry "$proc/13/task/16" 1000 S
ln -s "$shm/u1000-Shm_zombie" "$proc/13/task/16/fd/9"
mkdir -p "$proc/15"
printf 'State:\tS (x)\nUid:\t1000\t1000\t1000\t1000\n' > "$proc/15/status"
run "mixed" 1000
[[ $(left) == Shm_bare,target,u1000-Shm_fd,u1000-Shm_link,u1000-Shm_maps,u1000-Shm_nd,u1000-Shm_new,u1000-Shm_uid,u1000-Shm_zombie,u1001-Shm_prefix ]] \
  || fail "mixed: left $(left)"
logged "removed 1 of 5 old segments, 524304 bytes" || fail "mixed not logged: $(cat "$tmp/out")"
[[ $(< "$tmp/hook") == $'u1000-Shm_old 1000\nend 0' ]] || fail "mixed: unlink fsuid $(cat "$tmp/hook")"

reset
seg u1000-Shm_old 120
task 10 1000
r=0
MICROOS_SHM_DIR=$shm MICROOS_PROC=$proc HOOK_LOG=$tmp/hook setpriv --bounding-set -setuid python3 "$tmp/run.py" "$reap" 1000 > "$tmp/out" 2>&1 || r=$?
((r == 1)) || fail "no CAP_SETUID: exit $r: $(cat "$tmp/out")"
[[ $(left) == u1000-Shm_old ]] || fail "no CAP_SETUID: left $(left)"
logged "aborted, fsuid is 0, not 1000" || fail "no CAP_SETUID not logged: $(cat "$tmp/out")"

reset
seg u1000-Shm_a 120
seg u1000-Shm_b 120
seg u1000-Shm_src 120 1001
mv "$shm/u1000-Shm_src" "$tmp/src"
task 10 1000
SWAP=u1000-Shm_a SWAP_SRC=$tmp/src run "swap" 1000
[[ $(left) == u1000-Shm_a ]] || fail "swap: left $(left)"
[[ $(stat -c %u "$shm/u1000-Shm_a") == 1001 ]] || fail "swap: the other owner's file is gone"
logged "u1000-Shm_a changed before the unlink, kept" || fail "swap not logged: $(cat "$tmp/out")"
logged "removed 1 of 2 old segments" || fail "swap: b not removed: $(cat "$tmp/out")"

reset
seg u1000-Shm_a 120
seg u1000-Shm_b 120
mkdir "$tmp/src"
chown 1000:1000 "$tmp/src"
task 10 1000
SWAP=u1000-Shm_a SWAP_SRC=$tmp/src run "swap dir" 1000
[[ $(left) == u1000-Shm_a && -d $shm/u1000-Shm_a ]] || fail "swap dir: left $(left)"
logged "u1000-Shm_a changed before the unlink, kept" || fail "swap dir not logged: $(cat "$tmp/out")"
logged "removed 1 of 2 old segments" || fail "swap dir: b not removed: $(cat "$tmp/out")"

for what in maps fd; do
  reset
  seg u1000-Shm_old 120
  task 10 1000
  task 20 1001
  rm -r "$proc/20/$what"
  if [[ $what == maps ]]; then mkdir "$proc/20/maps"; else : > "$proc/20/fd"; fi
  run "unreadable $what" 1000
  [[ $(left) == u1000-Shm_old ]] || fail "unreadable $what: left $(left)"
  logged "reap skipped, pid 20:" || fail "unreadable $what not logged: $(cat "$tmp/out")"
done

for i in 0 999 abc "" "1000 1001"; do
  reset
  seg u0-Shm_old 120 0
  seg u999-Shm_old 120 999
  want=2 run "instance '$i'" $i
  [[ $(left) == u0-Shm_old,u999-Shm_old ]] || fail "instance '$i': left $(left)"
  logged "refusing instance" || fail "instance '$i' not logged: $(cat "$tmp/out")"
done

reset
seg u1000-Shm_new 5
run "nothing old" 1000
[[ $(left) == u1000-Shm_new && ! -s $tmp/out ]] || fail "nothing old: left $(left), out $(cat "$tmp/out")"

reset
seg u1000-Shm_a 120
seg u1000-Shm_b 120
seg u1000-Shm_c 120
task 1 1000
rm "$proc/1/maps"
mkfifo -m 644 "$proc/1/maps"
task 99 1000
MICROOS_SHM_DIR=$shm MICROOS_PROC=$proc HOOK_LOG=$tmp/hook python3 "$tmp/run.py" "$reap" 1000 > "$tmp/out" 2>&1 &
pid=$!
timeout 10 sh -c ': > "$1"' - "$proc/1/maps" || fail "race: first scan never read the fifo"
for _ in $(seq 1000); do
  find "/proc/$pid/fd" -lname "$proc/1/maps" 2> /dev/null | grep -q . || break
  sleep 0.01
done
sh -c 'sleep 15; : < "$1"' - "$proc/1/maps" 2> /dev/null &
wd=$!
exec 3> "$proc/1/maps"
fdhold 99 7 u1000-Shm_b
seg u1000-Shm_c.new 120
mv "$shm/u1000-Shm_c.new" "$shm/u1000-Shm_c"
seg u1000-Shm_d 120
exec 3>&-
r=0
for _ in $(seq 100); do kill -0 "$pid" 2> /dev/null || break; sleep 0.1; done
kill -0 "$pid" 2> /dev/null && { kill -9 "$pid"; fail "race: still running after 10 s"; }
wait "$pid" || r=$?
pid=""
kill "$wd" 2> /dev/null || true
wd=""
((r == 0)) || fail "race: exit $r: $(cat "$tmp/out")"
[[ $(left) == u1000-Shm_b,u1000-Shm_c,u1000-Shm_d ]] || fail "race: left $(left)"
logged "removed 1 of 3 old segments" || fail "race not logged: $(cat "$tmp/out")"

reset
rmdir "$shm"
want=1 run "no shm dir" 1000
logged "error:" || fail "no shm dir not logged: $(cat "$tmp/out")"

on=$'[Unit]\nOnSuccess=microos-shm-reap-request.service\nOnFailure=microos-shm-reap-request.service'
[[ $(< "$user/app-steam-.scope.d/50-microos-shm-reap.conf") == "$on" ]] || fail "Steam game scope drop-in"
[[ $(< "$user/microemu-game.scope.d/50-microos-shm-reap.conf") == "$on" ]] || fail "MicroEMU game scope drop-in"
start=/usr/bin/systemctl' --user start --no-block microos-shm-reap-request.service'
[[ $(< "$user/gamescope-session-plus@.service.d/50-microos-shm-reap.conf") == $'[Service]\nExecStartPre=-'"$start"$'\nExecStopPost=-'"$start" ]] \
  || fail "session drop-in"
grep -qx 'ExecStart=/usr/bin/systemctl start --no-block microos-shm-reap@%U.service' "$user/microos-shm-reap-request.service" \
  || fail "request service ExecStart"
for l in Type=oneshot 'ExecStart=/usr/libexec/microos/microos-shm-reap %i' TimeoutStartSec=30 ProtectSystem=strict \
  NoNewPrivileges=yes 'CapabilityBoundingSet=CAP_SYS_PTRACE CAP_DAC_READ_SEARCH CAP_SETUID'; do
  grep -qxF "$l" "$unit" || fail "reaper unit lacks $l"
done
! grep -qE '^(PrivateDevices|ProtectProc|AmbientCapabilities|User)=|^\[Install\]' "$unit" || fail "reaper unit blinds the reaper, drops CAP_SETUID or is installed"
grep -qF 'action.id != "org.freedesktop.systemd1.manage-units" || subject.user != "micro"' "$rule" || fail "polkit subject check"
grep -qF 'action.lookup("verb") == "start" && action.lookup("unit") == "microos-shm-reap@1000.service"' "$rule" || fail "polkit unit check"
[[ $(grep -c 'polkit.Result' "$rule") == 1 ]] || fail "polkit rule returns more than one result"

if ((rc == 0)); then
  echo "shm-reap: ok"
fi
exit "$rc"
