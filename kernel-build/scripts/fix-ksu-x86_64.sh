#!/bin/bash
# x86_64-only fixes applied after the Wild KSU<->SUSFS integration patch.
# Wild's ksud.h uses compat_uptr_t under CONFIG_COMPAT but does not include
# linux/compat.h; sucompat.c drops strncpy_from_user return checks; clang
# -Werror=division-by-zero trips on kernel headers pulled via extras.c;
# app_profile.c tests TIF_SECCOMP (arm64-only on 6.6); selinux_hide.c drops
# linux/kallsyms.h but still calls kallsyms_lookup_name.

set -euo pipefail

KERNEL_DIR="${1:?need path to kernel source tree}"
cd "${KERNEL_DIR}"

KSU_RT=drivers/kernelsu/runtime/ksud.h
if [[ -f "${KSU_RT}" ]] && ! grep -q 'linux/compat.h' "${KSU_RT}"; then
    echo "  - ${KSU_RT}: add linux/compat.h for compat_uptr_t"
    python3 - "${KSU_RT}" <<'PY'
import sys, re
path = sys.argv[1]
src = open(path).read()
inject = (
    "/* AVD_KSU_X86_FIX: compat_uptr_t needs linux/compat.h when CONFIG_COMPAT */\n"
    "#ifdef CONFIG_COMPAT\n"
    "#include <linux/compat.h>\n"
    "#endif\n\n"
)
m = re.search(r'^#ifndef __KSU_H_KSUD\n', src, re.M)
assert m, "ksud.h guard not found"
src = src[:m.end()] + inject + src[m.end():]
open(path, 'w').write(src)
PY
else
    echo "  - ${KSU_RT}: compat include already present"
fi

KBUILD=drivers/kernelsu/Kbuild
if [[ -f "${KBUILD}" ]] && ! grep -q 'Wno-error=division-by-zero' "${KBUILD}"; then
    echo "  - ${KBUILD}: allow division-by-zero in pulled-in kernel headers"
    sed -i '/^ccflags-y += -Wno-declaration-after-statement/a ccflags-y += -Wno-error=division-by-zero' \
        "${KBUILD}"
else
    echo "  - ${KBUILD}: division-by-zero ccflag already present"
fi

SC=drivers/kernelsu/feature/sucompat.c
if [[ -f "${SC}" ]]; then
    echo "  - ${SC}: restore strncpy_from_user return checks"
    python3 - "${SC}" <<'PY'
import sys, re
path = sys.argv[1]
src = open(path).read()
new = re.sub(
    r'^(\t)strncpy_from_user\(path, \*filename_user, sizeof\(path\)\);\s*$',
    r'\1if (strncpy_from_user(path, *filename_user, sizeof(path)) < 0)\n\1\treturn 0;',
    src,
    flags=re.M,
)
if new == src:
    print("    (no unchecked strncpy_from_user lines to fix)")
else:
    open(path, 'w').write(new)
PY
fi

AP=drivers/kernelsu/policy/app_profile.c
if [[ -f "${AP}" ]] && grep -q 'test_thread_flag(TIF_SECCOMP)' "${AP}"; then
    echo "  - ${AP}: use test_syscall_work(SECCOMP) on CONFIG_GENERIC_ENTRY"
    python3 - "${AP}" <<'PY'
import sys, re
path = sys.argv[1]
src = open(path).read()
old = (
    "\tif (likely(test_thread_flag(TIF_SECCOMP)))\n"
    "\t\tdisable_seccomp();"
)
new = (
    "#if defined(CONFIG_GENERIC_ENTRY) && LINUX_VERSION_CODE >= KERNEL_VERSION(5, 11, 0)\n"
    "\tif (likely(test_syscall_work(SECCOMP)))\n"
    "#else\n"
    "\tif (likely(test_thread_flag(TIF_SECCOMP)))\n"
    "#endif\n"
    "\t\tdisable_seccomp();"
)
if old not in src:
    raise SystemExit("app_profile.c TIF_SECCOMP guard not found")
open(path, 'w').write(src.replace(old, new, 1))
PY
else
    echo "  - ${AP}: seccomp guard already fixed or absent"
fi

SH=drivers/kernelsu/feature/selinux_hide.c
if [[ -f "${SH}" ]] && ! grep -q '<linux/kallsyms.h>' "${SH}"; then
    echo "  - ${SH}: restore linux/kallsyms.h include"
    sed -i '/#include <linux\/mutex.h>/a #include <linux/kallsyms.h>' "${SH}"
else
    echo "  - ${SH}: kallsyms include already present"
fi

echo "==> x86_64 KSU build fixes applied"
