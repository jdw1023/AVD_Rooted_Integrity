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
AVD_TEMPLATE_DIR="${REPO_ROOT}/device/avd-config"

AVD_NAME="${AVD:-pixel_9_pro_xl}"
KERNEL="${KERNEL:-$REPO_ROOT/kernel-build/out/bzImage}"
LOG="${LOG:-$REPO_ROOT/avd-boot.log}"
SHOW_KERNEL="${SHOW_KERNEL:-0}"
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

# hw.wifi.enabled=yes + VirtioWifi=off: mac80211_hwsim (our kernel has it);
# virtio-wifi-pci breaks boot with the custom kernel. syscall_hardening=off
# must reach the guest cmdline — config.ini kernel.parameters alone is often
# ignored on API 36, so we also pass it via -qemu -append.
AVD_DIR="$HOME/.android/avd/${AVD_NAME}.avd"
AVD_CFG="${AVD_DIR}/config.ini"
ADV_FEAT="${AVD_DIR}/advancedFeatures.ini"
if [[ -d "$AVD_DIR" ]]; then
    if [[ -f "$AVD_CFG" ]] && ! grep -q "^hw.wifi.enabled" "$AVD_CFG"; then
        echo "==> adding hw.wifi.enabled=yes to $AVD_CFG"
        echo "hw.wifi.enabled = yes" >> "$AVD_CFG"
    fi
    if [[ -n "${KERNEL_APPEND}" ]]; then
        if grep -q '^kernel.parameters' "$AVD_CFG" 2>/dev/null; then
            if ! grep '^kernel.parameters' "$AVD_CFG" | grep -qF "${KERNEL_APPEND}"; then
                echo "==> appending ${KERNEL_APPEND} to kernel.parameters in $AVD_CFG"
                sed -i "s/^\(kernel.parameters =.*\)$/\1 ${KERNEL_APPEND}/" "$AVD_CFG"
            fi
        else
            echo "==> adding kernel.parameters=${KERNEL_APPEND} to $AVD_CFG"
            echo "kernel.parameters = ${KERNEL_APPEND}" >> "$AVD_CFG"
        fi
    fi
    if [[ -f "${AVD_TEMPLATE_DIR}/advancedFeatures.ini" ]]; then
        echo "==> syncing advancedFeatures.ini (Wifi=on, VirtioWifi=off)"
        cp -f "${AVD_TEMPLATE_DIR}/advancedFeatures.ini" "$ADV_FEAT"
        # Emulator 36 also reads ~/.android/advancedFeatures.ini at startup; the
        # SDK copy defaults VirtioWifi=on and can override the per-AVD file.
        cp -f "${AVD_TEMPLATE_DIR}/advancedFeatures.ini" "$HOME/.android/advancedFeatures.ini"
    fi
    if [[ -f "$AVD_CFG" ]] && ! grep -q '^PlayStore.enabled' "$AVD_CFG"; then
        echo "==> adding PlayStore.enabled=yes to $AVD_CFG"
        echo "PlayStore.enabled = yes" >> "$AVD_CFG"
    fi
else
    echo "WARNING: AVD dir not found: $AVD_DIR (set AVD= to match your device name)" >&2
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
if [[ -n "${KERNEL_APPEND}" ]]; then
    echo "    cmdline:  ${KERNEL_APPEND} (via -qemu -append)"
fi
if [[ "${SHOW_KERNEL}" == "1" ]]; then
    echo "    kernel console: ttyS0 -> stdout (-qemu -serial stdio)"
fi
echo

KERNEL_APPEND_EFFECTIVE="$KERNEL_APPEND"
if [[ "${SHOW_KERNEL}" == "1" ]]; then
    # Emulator 36 no longer accepts -show-kernel (QEMU rejects it). Route the
    # guest serial port to stdout and override console=0 from the default append.
    KERNEL_APPEND_EFFECTIVE="${KERNEL_APPEND_EFFECTIVE} console=ttyS0 earlyprintk=serial"
fi

EMU_ARGS=(
    -avd "$AVD_NAME"
    -kernel "$KERNEL"
    -no-snapshot-load
    -no-snapshot-save
    -verbose
)
QEMU_FWD=()
if [[ "${SHOW_KERNEL}" == "1" ]]; then
    QEMU_FWD+=( -serial stdio )
fi
if [[ -n "${KERNEL_APPEND_EFFECTIVE}" ]]; then
    # config.ini kernel.parameters is not always merged on API 36; -qemu -append
    # is forwarded to qemu-system-x86_64 and does show up in the final cmdline.
    QEMU_FWD+=( -append "$KERNEL_APPEND_EFFECTIVE" )
fi
if [[ ${#QEMU_FWD[@]} -gt 0 ]]; then
    EMU_ARGS+=( -qemu "${QEMU_FWD[@]}" )
fi

# -no-snapshot-load forces a cold boot so the -kernel override actually fires.
exec "$EMU" "${EMU_ARGS[@]}" 2>&1 | tee "$LOG"
