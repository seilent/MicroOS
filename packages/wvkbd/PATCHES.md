# wvkbd patches

The RPM builds upstream `f7e9ea3a75` (tag `v0.21`, 2026-10-27, `SOURCE.env`) with `patches/` on top. Both patches are
mine, written new; upstream has no fix on `master`. There is no upstream test suite, so `%check` only runs the built
binary's `-v`.

| Patch | Origin | Why on the PM2 | Test |
|---|---|---|---|
| `0001-config-mk-keep-the-build-flags-from-the-environment.patch`: keep the build flags from the environment | mine | `config.mk` sets `CFLAGS =`, which discards the flags a build system puts in the environment, so distro hardening and `-fPIE` never reach the compile, and the link fails against the PIE default. Changing it to `CFLAGS +=` lets the environment's flags come first and the makefile's own `-D` flags still apply | a build without the patch fails to link with `relocation R_X86_64_32 ... can not be used when making a PIE object`; with it, `readelf -d` shows `BIND_NOW` and `nm -D` shows `__stack_chk_fail` |
| `0002-make-objects-wait-for-the-generated-config-header.patch`: objects wait for the generated config header | mine | only `main.c` includes `config.h`, which `$(BUILDDIR)/config.h` creates, and the objects do not depend on it, so under `-j` `main.o` can compile before the header exists. The rule adds the header to the object prerequisite line | on a clean tree `make -j LAYOUT=mobintl` fails before the patch and passes after it |
