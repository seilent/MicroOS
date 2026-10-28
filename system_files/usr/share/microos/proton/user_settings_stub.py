user_settings = {}

import builtins
import os
import signal
import stat
import sys
import threading
import time

_STATE = "MICROOS_PROTON_HOOK"
_FLAGS = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
_BUDGET = 2.0
_TICK = 0.05


def _say(msg):
    try:
        print(f"microos proton stub: {msg}", file=sys.stderr, flush=True)
    except BaseException:
        pass


def _read(path, limit, code):
    fd = os.open(path, _FLAGS)
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode):
            raise OSError(f"{path}: not a regular file")
        if code and st.st_mode & (stat.S_IWGRP | stat.S_IWOTH):
            raise OSError(f"{path}: writable by group or others")
        if st.st_size > limit:
            raise OSError(f"{path}: {st.st_size} bytes, over {limit}")
        data = b""
        while len(data) <= limit:
            b = os.read(fd, limit + 1 - len(data))
            if not b:
                break
            data += b
        if len(data) > limit:
            raise OSError(f"{path}: over {limit} bytes")
        return data
    finally:
        os.close(fd)


def _pair(k, v):
    if type(k) is not str or type(v) is not str or k == "" or "=" in k or "\0" in k or "\0" in v:
        return False
    try:
        os.fsencode(k)
        os.fsencode(v)
    except UnicodeError:
        return False
    return True


def _exec(path, src):
    ns = {"__name__": os.path.basename(path).removesuffix(".py"), "__file__": path, "__builtins__": builtins}
    exec(compile(src, path, "exec", dont_inherit=True), ns)
    return ns


def _call(path, src, ctx):
    old = signal.getsignal(signal.SIGALRM)
    if (threading.current_thread() is not threading.main_thread() or old is None
            or signal.SIGALRM in signal.pthread_sigmask(signal.SIG_BLOCK, ())):
        return _exec(path, src)["settings"](ctx)
    live = [True]
    fired = [False]

    def alarm(signum, frame):
        if live[0]:
            fired[0] = True
            raise TimeoutError(f"past its {_BUDGET:g} s budget")

    start = time.monotonic()
    delay, interval = signal.setitimer(signal.ITIMER_REAL, 0)
    try:
        signal.signal(signal.SIGALRM, alarm)
        signal.setitimer(signal.ITIMER_REAL, _BUDGET, _TICK)
        got = _exec(path, src)["settings"](ctx)
        if fired[0]:
            raise TimeoutError(f"past its {_BUDGET:g} s budget, its result dropped")
        return got
    finally:
        try:
            live[0] = False
        finally:
            try:
                signal.setitimer(signal.ITIMER_REAL, 0)
            finally:
                try:
                    signal.signal(signal.SIGALRM, old)
                finally:
                    if delay > 0:
                        signal.setitimer(signal.ITIMER_REAL, max(delay - (time.monotonic() - start), 1e-6), interval)


def _local(here):
    path = os.path.join(here, "user_settings_local.py")
    try:
        src = _read(path, 64 << 10, False)
    except FileNotFoundError:
        return {}, "ok"
    except BaseException as e:
        _say(f"bad-local: {e}")
        return {}, "bad-local"
    try:
        if _STATE.encode() in src:
            raise ValueError("it carries the MicroOS hook marker")
        names = _exec(path, src).get("user_settings")
        if not isinstance(names, dict):
            raise TypeError("it defines no user_settings dict")
        out = {}
        for k, v in names.items():
            if not _pair(k, v):
                _say(f"{path}: {k!r} dropped, not a str name with a str value")
            elif k.startswith("MICROOS_"):
                _say(f"{path}: {k!r} dropped, a MicroOS state name")
            else:
                out[k] = v
        return out, "ok"
    except BaseException as e:
        _say(f"bad-local: {path}: {type(e).__name__}: {e}")
        return {}, "bad-local"


def _hook(here, local, state):
    root = "/run/host/usr" if os.path.isdir("/run/host/usr") else "/usr"
    path = root + "/share/microos/proton/hook.py"
    try:
        src = _read(path, 256 << 10, True)
    except FileNotFoundError:
        _say(f"no-hook: {path}")
        return None, "no-hook"
    except BaseException as e:
        _say(f"hook-error: {e}")
        return None, "hook-error"
    try:
        got = _call(path, src, {"api": 1, "tool_dir": here, "local": dict(local), "local_state": state})
        if not isinstance(got, dict) or type(got.get("api")) is not int or got["api"] != 1:
            raise ValueError(f"api {got.get('api') if isinstance(got, dict) else got!r}, not 1")
        env = got.get("env")
        if not isinstance(env, dict) or not all(_pair(k, v) for k, v in env.items()) or _STATE not in env:
            raise ValueError("env is not a dict of str names to str values with the hook state")
        return dict(env), "ok"
    except BaseException as e:
        _say(f"hook-error: {path}: {type(e).__name__}: {e}")
        return None, "hook-error"


def _settings():
    here = os.path.dirname(os.path.abspath(__file__))
    local, state = _local(here)
    env, got = _hook(here, local, state)
    if env is not None:
        return env
    local[_STATE] = ",".join(s for s in (state, got) if s != "ok")
    return local


try:
    user_settings = _settings()
except BaseException as e:
    _say(f"hook-error: {type(e).__name__}: {e}")
    user_settings = {_STATE: "hook-error"}
