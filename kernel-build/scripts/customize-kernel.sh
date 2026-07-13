#!/bin/bash
# Inject anti-emulator modifications directly into the kernel source files
# instead of using diff/patch hunks (which break every time AOSP cherry-picks
# something into the branch). Each section is idempotent: if our marker
# comment is already present, the edit is skipped.
#
# Modifications:
#   1. kernel/module/procfs.c -- filter goldfish/qemu/virtio entries from
#      /proc/modules
#   2. arch/arm64/kernel/cpuinfo.c -- (arm64 only) print Tensor-G5-shaped CPU
#      implementer (0x41) and parts (Cortex-X4 / A720 / A520). On x86_64,
#      /proc/cpuinfo is spoofed at runtime via SUSFS open_redirect instead.
#   3. drivers/base/devtmpfs.c -- suppress devtmpfs nodes for
#      goldfish_* / qemu_* / ranchu_* names

set -euo pipefail

KERNEL_DIR="${1:?need path to kernel source tree}"
KERNEL_ARCH="${KERNEL_ARCH:-x86_64}"
cd "${KERNEL_DIR}"

MARKER='AVD_SPOOF_INJECTED'

# ============================================================================
# 1. /proc/modules filter
# ============================================================================
f=kernel/module/procfs.c
if grep -q "${MARKER}" "$f"; then
    echo "  - ${f}: already injected"
else
    echo "  - ${f}: injecting /proc/modules blocklist"
    python3 - "$f" <<'PY'
import sys, re
path = sys.argv[1]
src = open(path).read()

block = r'''
/* AVD_SPOOF_INJECTED: hide emulator-fingerprint modules from /proc/modules */
static const char * const avd_hidden_module_names[] = {
	"goldfish_pipe", "goldfish_sync", "goldfish_address_space",
	"goldfish_battery", "goldfish_audio", "goldfish_camera",
	"goldfish_fb", "goldfish_tty", "goldfish_nand",
	"virt_wifi", "mac80211_hwsim",
	"virtio_gpu", "virtio_dma_buf", "virtio_snd", "virtio_input",
	"virtio_net", "virtio_blk", "virtio_pmem", "virtio_console",
	"virtio_balloon", "virtio_rng",
	NULL,
};
static bool avd_module_hidden(const char *name)
{
	int i;
	for (i = 0; avd_hidden_module_names[i]; i++)
		if (!strcmp(name, avd_hidden_module_names[i]))
			return true;
	return false;
}
'''

# Insert block right before the m_show function definition.
m = re.search(r'^static int m_show\(struct seq_file \*m, void \*p\)\s*\{', src, re.M)
assert m, "m_show not found in " + path
src = src[:m.start()] + block + '\n' + src[m.start():]

# Inside m_show, add an early return if the module name is hidden.
# Look for the first statement after the opening brace of m_show.
m2 = re.search(
    r'(static int m_show\(struct seq_file \*m, void \*p\)\s*\{\s*\n'
    r'\tstruct module \*mod[^;]*;\s*\n[^\n]*\n)',
    src
)
assert m2, "couldn't locate body of m_show"
inject = '\n\tif (avd_module_hidden(mod->name))\n\t\treturn 0;\n'
src = src[:m2.end()] + inject + src[m2.end():]

open(path, 'w').write(src)
PY
fi

# ============================================================================
# 2. /proc/cpuinfo spoof (arm64 builds only)
# ============================================================================
if [[ "${KERNEL_ARCH}" == "arm64" ]]; then
f=arch/arm64/kernel/cpuinfo.c
if grep -q "${MARKER}" "$f"; then
    echo "  - ${f}: already injected"
else
    echo "  - ${f}: injecting Tensor-G5 MIDR spoof"
    python3 - "$f" <<'PY'
import sys, re
path = sys.argv[1]
src = open(path).read()

# Define the spoof helpers as a static block before c_show.
helper = r'''
/* AVD_SPOOF_INJECTED: Tensor G5 layout (cpu0 X4, cpu1-3 A720, cpu4-7 A520) */
struct avd_midr_entry { u8 variant; u8 implementer; u16 part; u8 revision; };
static const struct avd_midr_entry avd_midr_table[] = {
	{ 0x9, 0x41, 0xd4d, 0x1 },
	{ 0x9, 0x41, 0xd41, 0x1 },
	{ 0x9, 0x41, 0xd41, 0x1 },
	{ 0x9, 0x41, 0xd41, 0x1 },
	{ 0x9, 0x41, 0xd80, 0x1 },
	{ 0x9, 0x41, 0xd80, 0x1 },
	{ 0x9, 0x41, 0xd80, 0x1 },
	{ 0x9, 0x41, 0xd80, 0x1 },
};
static u32 avd_spoofed_midr(int cpu)
{
	const struct avd_midr_entry *e =
		&avd_midr_table[cpu < 0 || cpu >= (int)ARRAY_SIZE(avd_midr_table) ? 0 : cpu];
	return ((u32)e->implementer << 24)
	     | ((u32)(e->variant & 0xf) << 20)
	     | (0xfu << 16)
	     | ((u32)(e->part & 0xfff) << 4)
	     | (e->revision & 0xf);
}
'''

m = re.search(r'^static int c_show\(struct seq_file \*m, void \*v\)\s*\{', src, re.M)
assert m, "c_show not found"
src = src[:m.start()] + helper + '\n' + src[m.start():]

# Replace every MIDR_*(midr) with the spoofed equivalent. The variable `i` is
# the per-cpu index already in scope in c_show (for_each_online_cpu(i)).
src = re.sub(r'MIDR_IMPLEMENTOR\(midr\)', 'MIDR_IMPLEMENTOR(avd_spoofed_midr(i))', src)
src = re.sub(r'MIDR_VARIANT\(midr\)',      'MIDR_VARIANT(avd_spoofed_midr(i))',     src)
src = re.sub(r'MIDR_PARTNUM\(midr\)',      'MIDR_PARTNUM(avd_spoofed_midr(i))',     src)
src = re.sub(r'MIDR_REVISION\(midr\)',     'MIDR_REVISION(avd_spoofed_midr(i))',    src)
# midr and the cpuinfo pointer that fed it are both unused now; strip them
# (otherwise -Werror=unused-variable blocks the build).
src = re.sub(r'^\s*u32\s+midr\s*=\s*cpuinfo->reg_midr\s*;\s*\n', '\n', src, flags=re.M)
src = re.sub(r'^\s*struct\s+cpuinfo_arm64\s*\*\s*cpuinfo\s*=\s*[^;]+;\s*\n', '\n', src, flags=re.M)

open(path, 'w').write(src)
PY
fi
else
    echo "  - /proc/cpuinfo: skipped at kernel level on ${KERNEL_ARCH} (SUSFS open_redirect serves avd-fake/cpuinfo)"
fi

# ============================================================================
# 3. devtmpfs node suppression -- DISABLED
# ============================================================================
# Kernel-level suppression of goldfish_*/qemu_*/ranchu_* /dev nodes breaks
# the AVD bringup: /dev/goldfish_pipe and /dev/goldfish_sync are the only
# host-guest channels init relies on. Hiding them here gives a stuck-at-init
# boot. The right tool is SUSFS sus_path applied at runtime against the same
# names, which our 02-avd-deeper-spoof.sh on-device script already handles.
echo "  - drivers/base/devtmpfs.c: SKIPPED (would break AVD init)"

echo "==> kernel customization complete"
