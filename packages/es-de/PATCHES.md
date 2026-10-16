# es-de patches

The RPM builds the ES-DE commit in `SOURCE.env` with `patches/` on top. `%check` builds `escape-test.cpp` with the
patched `es-core/src/utils/FileSystemUtil.cpp` (`--gc-sections` drops the parts that need the rest of es-core) and
runs it.

| Patch | Origin | Why on MicroOS | Test |
|---|---|---|---|
| `0001-escape-every-shell-special-byte-in-unix-launch-paths.patch` | mine, written new; upstream `master` has no fix | ES-DE puts `getEscapedPath` output into the launch command it runs through `/bin/sh`, and 3.5.0 leaves backtick, `\|`, newline, tab, `#` and `~` unescaped and skips a character that follows a backslash, so a ROM name on the SD card could run a command. Every byte outside `[A-Za-z0-9/._-+,:@%]` below 0x80 gets a backslash, a newline goes in double quotes. The output stays backslash escaped, so the callers that strip backslashes to get the plain path (`%GAMEDIR%`, `%EMUPATH%`, desktop files, scripting events) keep working | `escape-test`: 18 names with backtick, `\|`, `$( )`, newline, tab, quotes, `&`, `;`, `>`, globs, `#`, `~`, `$HOME`, `!`, a backslash before `$( )` and UTF-8 round trip through `sh -c "printf '%s' <path>"` (against `getGenericPath`, which turns `\` into `/`) and none runs the canary script; on unpatched 3.5.0 the backtick, `\|` and newline names run it |
