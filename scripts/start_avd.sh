#!/usr/bin/env bash
# Cold-boot a rooted Pixel AVD with the custom kernel built by kernel-build/.
#
# This uses the Android SDK already installed on your host (Android Studio or
# cmdline-tools). It does NOT bundle the emulator or a system image — see the
# README for the AVD you need to create first.
#
# Requirements:
#   - Android SDK with `emulator` + a Pixel system image (google_apis_playstore)
#   - adb on PATH
#   - A custom kernel at kernel-build/out/bzImage (run kernel-build first)
#
# Override defaults with env vars:
#   AVD=Pixel_9_Pro_XL ./scripts/start_avd.sh
#   KERNEL=/abs/path/bzImage ./scripts/start_avd.sh
#   EMULATOR=/abs/path/emulator ./scripts/start_avd.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

AVD_NAME="${AVD:-Pixel_9_Pro_XL}"
KERNEL="${KERNEL:-$REPO_ROOT/kernel-build/out/bzImage}"
LOG="${LOG:-$REPO_ROOT/avd-boot.log}"
# x86_64 syscall-hardening bypass: required when using kernel source patches
# (see kernel-build/README.md). Do not set if you switch to
# CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER instead.
KERNEL_APPEND="${KERNEL_APPEND:-syscall_hardening=off}"

# Resolve emulator: explicit env, then ANDROID_SDK_ROOT, then common defaults.
if [[ -n "${EMULATOR:-}" ]]; then
    EMU="$EMULATOR"
elif [[ -n "${ANDROID_SDK_ROOT:-}" && -x "$ANDROID_SDK_ROOT/emulator/emulator" ]]; then
    EMU="$ANDROID_SDK_ROOT/emulator/emulator"
elif [[ -x "$HOME/Android/Sdk/emulator/emulator" ]]; then
    EMU="$HOME/Android/Sdk/emulator/emulator"
else
    EMU="$HOME/Library/Android/sdk/emulator/emulator"
fi

if [[ ! -x "$EMU" ]]; then
    echo "ERROR: emulator binary not found (looked at: $EMU)" >&2
    echo "Install it via Android Studio, or set EMULATOR=/path/to/emulator" >&2
    exit 1
fi
if [[ ! -f "$KERNEL" ]]; then
    echo "ERROR: kernel image not found at $KERNEL" >&2
    echo "Build it first:  see kernel-build/README.md" >&2
    exit 1
fi
command -v adb >/dev/null 2>&1 || { echo "ERROR: adb not on PATH" >&2; exit 1; }

# hw.wifi.enabled=yes is required: it makes QEMU bring up mac80211_hwsim, which
# the boot scripts wrap as wlan0 via virt_wifi. Patch it in idempotently.
AVD_CFG="$HOME/.android/avd/${AVD_NAME}.avd/config.ini"
if [[ -f "$AVD_CFG" ]] && ! grep -q "^hw.wifi.enabled" "$AVD_CFG"; then
    echo "==> adding hw.wifi.enabled=yes to $AVD_CFG"
    echo "hw.wifi.enabled = yes" >> "$AVD_CFG"
fi

# Cold boot needs a clean slate.
if adb devices 2>/dev/null | grep -q emulator; then
    echo "==> killing running emulator first"
    adb emu kill >/dev/null 2>&1 || true
    sleep 3
fi

echo "==> Booting $AVD_NAME with custom kernel:"
echo "    kernel:   $KERNEL"
echo "    emulator: $EMU"
echo "    log:      $LOG"
echo

# -no-snapshot-load forces a cold boot so the -kernel override actually fires.
exec "$EMU" -avd "$AVD_NAME" \
    -kernel "$KERNEL" \
    -append "$KERNEL_APPEND" \
    -no-snapshot-load \
    -no-snapshot-save \
    -verbose 2>&1 | tee "$LOG"
