# Prerequisite root modules

The on-device integrity setup in `data_adb/` is **configuration + scripts only**.
It assumes a rooted AVD with the following KernelSU modules already installed.
Their binaries are third-party and are not vendored here — install them from
their own releases, then apply our configs with `../scripts/install-device-setup.sh`.

The versions below are the ones this setup was validated against. Newer
versions usually work, but SUSFS in particular is tightly coupled to the kernel
(`add_open_redirect` / `sus_map` behavior changed across versions).

| Module | Validated version | Role | Source |
|---|---|---|---|
| **KernelSU-Next** | commit `5a4a718…` (matches kernel) | Root framework; provides `su`, `resetprop`, `ksu_susfs`. | <https://github.com/KernelSU-Next/KernelSU-Next> |
| **SUSFS for KernelSU** | v2.1.0-R27 (`susfs4ksu`) | Userspace half of SUSFS: `/proc/*` open-redirects, `sus_path`, `sus_map`, uname spoof. Reads `/data/adb/susfs4ksu/*`. | <https://gitlab.com/simonpunk/susfs4ksu> |
| **TEESimulator** (`tricky_store`) | v3.2 (build 67) | Forges the hardware attestation chain from the keybox. Reads `/data/adb/tricky_store/`. | <https://github.com/JingMatrix/TEESimulator> |
| **Play Integrity Fork** (`playintegrityfix`) | v16 | Spoofs `Build.*` + props to the Pixel 9 profile in `pif/custom.pif.prop`. | <https://github.com/osm0sis/PlayIntegrityFork> |
| **ReZygisk** | v1.0.0 | Zygisk implementation that injects PIF + Vector into zygote. | <https://github.com/PerformanC/ReZygisk> |
| **Vector** (`zygisk_vector`, LSPosed fork) | v2.0 (3021) | Zygisk-based hook manager. (Only needed if you also run LSPosed-style modules; for pure PI it can be omitted.) | <https://github.com/JingMatrix/LSPosed> |

## Validated download URLs (reproduced clean-room 2026-05-29)

These exact releases were installed from scratch on a fresh AVD with the repo's
kernel and produced a working attestation chain:

```bash
# KSU-Next manager APK (adb install -r)
https://github.com/KernelSU-Next/KernelSU-Next/releases/download/v3.2.0/KernelSU_Next_v3.2.0_33129-release.apk

# KSU module zips (ksud module install <zip>)
https://github.com/sidex15/susfs4ksu-module/releases/download/v1.5.2%2B_R27/ksu_module_susfs_1.5.2%2B.zip
https://github.com/PerformanC/ReZygisk/releases/download/v1.0.0/ReZygisk-v1.0.0-release.zip
https://github.com/osm0sis/PlayIntegrityFork/releases/download/v16/PlayIntegrityFork-v16.zip
https://github.com/JingMatrix/TEESimulator/releases/download/v3.2/TEESimulator-v3.2-67-Release.zip
```

Install the manager, launch it once (registers with the kernel — KSU-Next then
grants `su` to the adb shell), then:

```bash
KSUD=/data/adb/ksu/bin/ksud
for z in susfs rezygisk pif tee; do
  adb push mod_$z.zip /data/local/tmp/
  adb shell "su -c '$KSUD module install /data/local/tmp/mod_$z.zip'"
done
# Then run scripts/install-device-setup.sh — it installs your keybox AND the
# custom.pif.prop profile (into both modules/ and modules_update/ so PIF can't
# autopif-fetch a different profile), and cold-reboot.
adb reboot
```

> Do **not** run `autopif` on the real AVD. It overwrites `custom.pif.prop` with
> a drifting profile (e.g. `felix`/Pixel Fold) on every boot, breaking the
> single-source consistency. See docs/REPRODUCTION.md §7.

## Install order

1. Build + boot the custom kernel (`kernel-build/`), which has `CONFIG_KSU` +
   SUSFS compiled in. Install the **KernelSU-Next** manager app and confirm
   `adb shell su -c id` returns `uid=0`.
2. Install **SUSFS**, **TEESimulator**, **PlayIntegrityFork**, **ReZygisk**
   (and **Vector** if used) as KSU modules, then reboot.
3. Run `../scripts/install-device-setup.sh` to push our scripts/configs and your
   keybox.
4. Reboot once more so `post-fs-data.d/` and `service.d/` run from a clean boot.

## What our configs override

- `pif/custom.pif.prop` → `/data/adb/modules/playintegrityfix/custom.pif.prop`.
  **This is the single source of truth for the device identity** (see below).
  `install-device-setup.sh` now copies it for you (it requires PIF to be
  installed first).
- `data_adb/tricky_store/{target.txt,security_patch.txt,tee_status.txt}` and your
  `keybox.xml` (installed 0644 so the injected TEESimulator can read it).
- `data_adb/susfs4ksu/*` — the SUSFS rule files.
- `data_adb/avd-fake/*` — the fake `/proc/*` and `/vendor/build.prop` contents.
  Note `vendor_build.prop` / `odm_build.prop` / `dt_compatible` /
  `security_patch.txt` are **regenerated at every boot** by `00-make-fakes.sh`
  from the active profile + the AVD's live partition; the committed copies are
  only a fallback.

## Single source of truth + version adaptivity (IMPORTANT for reproducibility)

The whole spoof is driven from **one file**: `device/pif/custom.pif.prop`.

- `00-make-fakes.sh` parses it into `/data/adb/avd-fake/profile.env`, then
  generates the version-specific files from it + the AVD's **own live**
  `/vendor/build.prop` (rewriting only the identity lines, keeping the native
  version/sdk/patch-level fields).
- `01-avd-prop-spoof.sh` applies every per-partition prop + fingerprint from the
  same `profile.env`.
- PIF itself reads `custom.pif.prop` for the `Build.*` spoof.

So all three layers (keymint per-partition IDs, the bind-mounted build.prop, and
the GMS-visible `Build` object) can never disagree — disagreement is what causes
`CANNOT_ATTEST_IDS` / an empty verdict. **To change the device or match a
different Android version, edit only `custom.pif.prop` and cold reboot.**

### Using a different Android version

The repo's custom kernel is GKI `android15-6.6` (6.6.66); it boots Android
14/15/16 `google_apis_playstore x86_64` system images. The version-specific
partition fields are taken from your image automatically (above), so you do **not**
need to hand-edit build.props. You should still pick a `custom.pif.prop` profile
whose device is a real Pixel; ideally one from a similar Android era. The module
versions below are the validated set — for a much newer system image you may need
newer module releases (use each project's latest release).
