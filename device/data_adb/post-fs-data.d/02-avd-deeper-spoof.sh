#!/system/bin/sh
# Deeper AVD-detection hiding: /proc/{cpuinfo,version,cmdline,modules}
# redirected via SUSFS to fake files, and AVD-specific /dev nodes
# (qemu_pipe) hidden via SUSFS sus_path.
#
# NOTE: we used to also sus_path /dev/goldfish_address_space, _sync, and
# _pipe_dprctd, but on the newer SUSFS we ship with the custom kernel,
# those sus_path entries also block system services like mapper.ranchu
# from opening them -- which fails graphics bringup ("GoldfishAddressSpace
# HostMemoryAllocator failed to open") and gives a black screen. We now
# leave the goldfish devnodes visible; apps detect by reading /proc/cpuinfo
# etc. which we still spoof, and by directly opening goldfish_* which we
# can't hide here without breaking SurfaceFlinger.

LOG=/data/adb/avd-deeper-spoof.log
SUSFS=/data/adb/ksu/bin/ksu_susfs
FAKE_DIR=/data/adb/avd-fake

{
  echo "=== $(date) avd-deeper-spoof start ==="

  if [ ! -d "$FAKE_DIR" ]; then
    echo "WARN: $FAKE_DIR missing -- skip redirects"
    exit 0
  fi

  if [ -f "$FAKE_DIR/cpuinfo" ]; then
    $SUSFS add_open_redirect /proc/cpuinfo "$FAKE_DIR/cpuinfo" 2>&1
    echo "redirect /proc/cpuinfo"
  fi
  if [ -f "$FAKE_DIR/version" ]; then
    $SUSFS add_open_redirect /proc/version "$FAKE_DIR/version" 2>&1
    echo "redirect /proc/version"
  fi
  if [ -f "$FAKE_DIR/modules" ]; then
    $SUSFS add_open_redirect /proc/modules "$FAKE_DIR/modules" 2>&1
    echo "redirect /proc/modules"
  fi
  if [ -f /data/adb/susfs4ksu/spoofed_cmdline ]; then
    $SUSFS add_open_redirect /proc/cmdline /data/adb/susfs4ksu/spoofed_cmdline 2>&1
    echo "redirect /proc/cmdline"
  fi

  # Hide ONLY qemu-named devnodes. Not goldfish_* (system services need those).
  for node in /dev/qemu_pipe /dev/qemu_trace; do
    if [ -e "$node" ]; then
      $SUSFS add_sus_path "$node" 2>&1
      echo "sus_path $node"
    fi
  done

  # Hide every Zygisk module's injected .so file from /proc/self/maps.
  # Without this, gms.unstable and com.android.vending can see the strings
  # "playintegrityfix", "zygisk_vector", "rezygisk", "tricky_store" in
  # their own memory map -- that's a direct Play Integrity failure.
  for so in \
      /data/adb/modules/playintegrityfix/zygisk/x86_64.so \
      /data/adb/modules/zygisk_vector/zygisk/x86_64.so \
      /data/adb/modules/rezygisk/lib64/libzygisk.so \
      /data/adb/modules/tricky_store/libTEESimulator.so
  do
      [ -f "$so" ] && $SUSFS add_sus_map "$so" 2>&1 && echo "sus_map $so"
  done

  echo "=== done ==="
} >> "$LOG" 2>&1
