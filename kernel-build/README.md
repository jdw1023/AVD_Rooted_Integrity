# Custom kernel build for AVD anti-detection

A reproducible Docker build of AOSP `common-android15-6.6` with KernelSU-Next,
SUSFS, and in-tree anti-emulator source customizations that hide the bulk of
QEMU/goldfish/ranchu fingerprints from userspace.

## What this gives you

| Layer | What |
|---|---|
| AOSP common-android15-6.6 | The kernel matching the AVD's existing 6.6.x |
| KernelSU-Next | Same root framework the KSU app talks to |
| SUSFS (gki-android15-6.6) | SUSFS features, at the version that supports `uid_scheme` on `add_open_redirect` |
| Module vermagic bypass | Lets the AVD's prebuilt `.ko` files load despite the rebuilt kernel's vermagic — without it, mediaswcodec's driver chain never comes up and the apex SIGABRTs |
| `CONFIG_LSM` without `baseband_guard` | The LSM stack we want; AOSP common doesn't ship baseband_guard |
| `/proc/modules` filter | goldfish_*, virtio_*, mac80211_hwsim hidden from the module list |
| `/proc/cpuinfo` spoof | On x86_64: runtime SUSFS open_redirect to `avd-fake/cpuinfo` (Tensor layout). Kernel-level injection is arm64-only. |
| Kernel banner | `LOCALVERSION` says `Pixel10Pro`, not `Wild`/`ranchu` |
| x86_64 syscall hardening bypass | Kernel source patches + `syscall_hardening=off` cmdline so KernelSU syscall hooks work on 6.6+ |

These customizations are injected **directly into the kernel source** by
`scripts/customize-kernel.sh` (Python edits guarded by an `AVD_SPOOF_INJECTED`
marker), not as `diff`/`patch` hunks — patch hunks break every time AOSP
cherry-picks something onto the branch, so source injection is more robust.

## What it does *not* fix

These need a different surface than the kernel:

- **`/dev/goldfish_*` device nodes.** Kernel-level suppression breaks AVD init
  (`/dev/goldfish_pipe` and `_sync` are the host↔guest channels init relies on).
  The on-device SUSFS `sus_path` / `add_open_redirect` approach handles the
  detectable surfaces (`/proc/*`) at runtime instead — see `../device/`.
- **Sensor vendor names** ("Goldfish 3-axis Accelerometer | The Android Open
  Source Project"). The sensor HAL lives in `vendor.img`. This is a known,
  unaddressed gap in this repo — it is not required for the Play Integrity
  verdict, only for evading deeper gms.unstable hardware-shape heuristics.
- **The attestation verdict itself.** `MEETS_STRONG_INTEGRITY` does *not* come
  from the kernel — it comes from TEESimulator forging a complete keybox-rooted
  attestation chain in GENERATE mode (see `../docs/INTEGRITY_CHAIN.md`). The
  kernel's job is only to keep emulator tells out of `/proc` so the rest of the
  chain holds; with that plus your own keybox, the verdict reaches **strong**
  integrity — no StrongBox hardware needed.

## Build it

### Time and disk

- ~3 GB of kernel source downloaded on first run
- ~3 GB of clang toolchain in the Docker image
- ~5–25 min to build, depending on cores + ccache state
- Total disk: ~10 GB inside the build dir

### Steps

```bash
cd kernel-build

# 1. Build the Docker image (one-time; reused on rebuild)
docker build -t kbuild .

# 2. Sync sources, apply patches, build kernel.
#    sources/ MUST live in a named volume, not a host bind mount — see below.
docker run --rm \
    -v "$PWD":/work \
    -v kbuild-sources:/work/sources \
    -w /work kbuild ./scripts/build-all.sh
```

Output (copied to the host bind mount): `out/bzImage`.

> **Why the `kbuild-sources` named volume is required.** The AOSP kernel tree
> contains files that differ only in case (e.g.
> `…+pooncelock+poonceLock+….litmus` vs `…+pooncelock+pooncelock+….litmus`).
> On macOS (case-insensitive APFS) those collide, so a host bind mount of
> `sources/` makes `git reset --hard` fail with *"unable to create file … File
> exists"* and the build never starts. A Docker **named volume** lives on
> Docker's case-sensitive Linux filesystem, so the checkout succeeds. `out/`
> stays on the host bind mount (just two files, no collision) so you can grab
> `bzImage`. On a case-sensitive Linux host you can drop the named volume, but
> it's harmless to keep.

## x86_64 support

This build targets **`x86_64`** (the `google_apis_playstore x86_64` AVD system
image). KernelSU Next fully supports x86_64, but newer kernels harden the syscall
path with direct branches, which blocks KSU's syscall-table hooking unless you
handle it.

### Why it breaks

[This upstream commit](https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git/commit/?id=1e3ad78334a69b36e107232e337f9d693dcc9df2)
converted indirect branches in the x86_64 syscall path into direct conditional
branches. KernelSU's `syscall_hook` modifies syscall-table entries to route
intercepted calls through its unified dispatcher; with hardening enabled, those
modifications are ignored and KSU aborts initialization to avoid a panic.

### How this repo fixes it (pick one method — not both)

**We use Option 2** (kernel source patches), because the pinned KernelSU commit
predates `CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER` (added in KSU 3.2.6+).

| Method | What we do |
|---|---|
| **Option 1** (KSU 3.2.6+ only) | Enable `CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER=y` in `build.sh` and **remove** the `patches/x86_64/` step from `apply-patches.sh`. Do **not** pass `syscall_hardening=off`. |
| **Option 2** (this repo) | Apply `patches/x86_64/01-*.patch` + `02-*.patch` (from [android-generic/kernel_common](https://github.com/android-generic/kernel_common) 6.6 commits `fe9a9b4` + `df772e9`). Boot with `syscall_hardening=off` (`start_avd.sh` passes this via `-append`). |

> **Security warning:** Either option intentionally bypasses or weakens a
> mitigation against speculative-execution attacks on the syscall path. **Do not
> use this on production systems** where side-channel security is critical. This
> is for testing environments where KernelSU root is prioritized.

For other kernel versions, see [KernelSU Next x86_64 docs](https://github.com/KernelSU-Next/KernelSU-Next/blob/master/website/docs/guide/x86_64-support.md)
(6.12 / 6.18 patch links there).

### Per-step (useful when iterating)

```bash
V="-v $PWD:/work -v kbuild-sources:/work/sources -w /work"
docker run --rm $V kbuild ./scripts/fetch-sources.sh
docker run --rm $V kbuild ./scripts/apply-patches.sh
docker run --rm $V kbuild ./scripts/build.sh
```

### Reset the source tree if patches fail to apply

Run inside the container (the tree lives in the named volume, not on the host):

```bash
docker run --rm -v "$PWD":/work -v kbuild-sources:/work/sources -w /work kbuild \
    bash -c 'rm -f sources/kernel/.avd-patches-applied && \
             cd sources/kernel && git reset --hard && git clean -fdx'
```

To wipe sources entirely and re-fetch: `docker volume rm kbuild-sources`.

## Boot the AVD with the new kernel

Use the repo-root launcher (uses your host Android SDK):

```bash
../scripts/start_avd.sh
# or override the AVD name / kernel:
AVD=Pixel_9_Pro_XL KERNEL="$PWD/out/bzImage" ../scripts/start_avd.sh
```

It passes `-kernel out/bzImage -append syscall_hardening=off -no-snapshot-load
-no-snapshot-save` to the emulator. The AVD's system/vendor/userdata stay exactly
as they were — only the kernel changes.

## What to verify after boot

```bash
# 1. /proc/modules doesn't list goldfish/hwsim/virtio
adb shell 'su -c "grep -iE \"goldfish|hwsim|virtio\" /proc/modules | wc -l"'   # → 0

# 2. /proc/cpuinfo shows implementer 0x41 (via SUSFS redirect to avd-fake/cpuinfo)
adb shell 'su -c "grep -m1 implementer /proc/cpuinfo"'                          # → 0x41

# 3. KSU is active
adb shell 'su -c "zcat /proc/config.gz | grep -E \"CONFIG_KSU=|CONFIG_KSU_SUSFS=\""'

# 4. ReZygisk healthy
adb shell 'su -c "grep description /data/adb/modules/rezygisk/module.prop"'
```

## How the scripts pin versions

`scripts/fetch-sources.sh` pins exact tags/commits so the build is reproducible:

| Source | Pin |
|---|---|
| AOSP common kernel | tag `android15-6.6-2025-02_r19` (matches the AVD's 6.6.66 vintage; branch HEAD is far ahead and Android 16 userspace SIGABRTs against it) |
| KernelSU-Next | commit `5a4a71874caa…` (the exact commit Wild Kernels uses) |
| SUSFS | branch `gki-android15-6.6`, commit `2df41de78902…` |
| Wild kernel_patches | HEAD — only their KSU↔SUSFS integration patch is used, which disables the aggressive syscall hooks that crash Android 16's mediaswcodec |

## Troubleshooting

**`fetch-sources.sh` is slow on AOSP gerrit.** Expected; the clone is
single-shot and cached. Subsequent runs skip.

**Source customization didn't apply.** `customize-kernel.sh` is idempotent and
guarded by an `AVD_SPOOF_INJECTED` marker comment. If a customization is
missing, AOSP moved the function it anchors on (e.g. `m_show` in
`kernel/module/procfs.c`). On x86_64, `/proc/cpuinfo` is not kernel-patched —
check that `02-avd-deeper-spoof.sh` redirected it to `avd-fake/cpuinfo`. The
Python `assert`s will fail loudly pointing at the function that moved; adjust
the anchor regex in `customize-kernel.sh` to match the new context.

**Build fails with `<asm/...>: No such file or directory`.** clang's
`--target=x86_64-linux-gnu` isn't finding the sysroot. Inside the container,
confirm `clang --target=x86_64-linux-gnu --print-search-dirs`.

**AVD won't boot the new kernel.** Look at `../avd-boot.log` — a panic in init
usually means a driver we depend on got disabled. `build.sh` deliberately keeps
`CONFIG_GOLDFISH_*`/`CONFIG_VIRTIO_*` as `=m` (not forced `=y`) so init's insmod
calls still succeed; don't change that.

**KSU build fails on x86_64 (`compat_uptr_t`, `strncpy_from_user`,
`division by zero`, `TIF_SECCOMP`, `kallsyms_lookup_name`).** Re-run
`apply-patches.sh` — step 4b runs `fix-ksu-x86_64.sh` after the Wild patch.
It adds `linux/compat.h` to `ksud.h`, restores `strncpy_from_user` checks in
`sucompat.c`, relaxes `-Werror=division-by-zero` for KSU objects, switches
the seccomp guard in `app_profile.c` to `test_syscall_work(SECCOMP)` on
x86_64, and re-adds `linux/kallsyms.h` to `selinux_hide.c`. If you patched
manually, run `bash scripts/fix-ksu-x86_64.sh sources/kernel` in the container.

**KSU shows "not installed" after boot.** `CONFIG_KSU` didn't land, or x86_64
syscall hardening blocked hook init. Confirm with `zcat /proc/config.gz | grep KSU`.
Check `dmesg` for KernelSU init errors. If you disabled the kernel patches,
ensure `syscall_hardening=off` is on the cmdline (`adb shell cat /proc/cmdline`)
or enable `CONFIG_KSU_X86_PATCH_SYSCALL_DISPATCHER` instead (not both). Re-run
`apply-patches.sh` with `bash -x` if integration failed.
