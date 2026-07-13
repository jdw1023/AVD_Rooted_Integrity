#!/bin/bash
# Build the AOSP common-android15-6.6 kernel with our patches applied.
# Output: sources/kernel/arch/x86_64/boot/bzImage
#
# Re-run safe: incremental builds work via ccache.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KERNEL_DIR="${ROOT}/sources/kernel"

if [[ ! -f "${KERNEL_DIR}/.avd-patches-applied" ]]; then
    echo "ERROR: patches not yet applied. Run scripts/apply-patches.sh first." >&2
    exit 1
fi

cd "${KERNEL_DIR}"

# With LLVM=1 LLVM_IAS=1 the kernel uses clang for compilation, integrated
# assembler, ld.lld for linking, llvm-objcopy. CROSS_COMPILE is still set so
# helpers that shell out to ${CROSS_COMPILE}gcc find x86_64-linux-gnu-gcc.
export ARCH=x86_64
export CROSS_COMPILE=x86_64-linux-gnu-
export LLVM=1
export LLVM_IAS=1
# ccache wraps via /usr/lib/ccache symlinks already on PATH
export CC=clang
export HOSTCC=clang
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export STRIP=llvm-strip

JOBS="${JOBS:-$(nproc)}"

echo "==> defconfig"
make -j "${JOBS}" gki_defconfig

# Append config overrides:
#  - KernelSU + every SUSFS feature
#  - LSM stack without baseband_guard (the Wild kernel added it; AOSP common
#    doesn't ship it, so we just guarantee the value we want)
#  - LOCALVERSION/host so the kernel banner doesn't say "android15-6.6-Wild"
cat >> .config <<'EOF'
CONFIG_KSU=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_MAP=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_LSM="landlock,lockdown,yama,loadpin,safesetid,selinux,smack,tomoyo,apparmor,bpf"
CONFIG_LOCALVERSION="-android16-5-Pixel10Pro"
# CONFIG_LOCALVERSION_AUTO is not set
CONFIG_DEFAULT_HOSTNAME="localhost"
# We do NOT force virtio_*/goldfish_*/dmabuf/binder/drm to =y. The defconfig
# leaves them as =m to match the AVD's prebuilt /lib/modules/*.ko, and Wild's
# vermagic-bypass hack (applied earlier in apply-patches.sh) lets those .ko
# files load despite version mismatch. Forcing them =y would cause init's
# insmod calls to fail with "Device or resource busy" -> kernel panic.
EOF
make -j "${JOBS}" olddefconfig

echo "==> Build (parallel jobs=${JOBS})"
time make -j "${JOBS}" bzImage

echo
echo "==> Build complete"
ls -la arch/x86_64/boot/bzImage | sed 's|^|    |'

# Copy the kernel image out of the named-volume source tree into the host-
# bind-mounted /work/out/ so start_avd.sh on the host can find it. Do this
# BEFORE the banner-print pipeline below -- grep -m1 closes its stdin which
# gives `strings` SIGPIPE, which with pipefail set would abort the script
# right before we copied the output. Copy first, then the banner is decorative.
OUTDIR="${ROOT}/out"
mkdir -p "${OUTDIR}"
cp -fv arch/x86_64/boot/bzImage "${OUTDIR}/bzImage"
echo
echo "==> Kernel image copied to host at: kernel-build/out/bzImage"

echo
echo "Kernel build version banner:"
( strings arch/x86_64/boot/bzImage || true ) | grep -m1 "Linux version" | sed 's|^|    |' || true
