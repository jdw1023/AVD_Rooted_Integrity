# Reproduction guide + post-mortem — rooted Pixel AVD passing Play Integrity

This is the complete, battle-tested guide to standing up a Google-Play Android
emulator (AVD) that **passes Play Integrity** with a populated device verdict,
plus a full post-mortem of the one bug that made this take days instead of hours.

If you only read one thing, read **§7 "The generate-vs-patch trap"** and
**§8 "The one rule"**. That is the part nobody documents and the part that will
waste your time if you don't know it.

---

## TL;DR — what actually matters

1. Build the custom kernel (KSU-Next + SUSFS + anti-emulator patches).
2. Boot the AVD on that kernel; install KSU-Next + the 4 modules.
3. Push `device/data_adb/` + your **keybox.xml** (must be `0644`, not `0600`).
4. Put the **tokay** `custom.pif.prop` in place — **do not run `autopif`** (it
   drifts to a `felix`/`Pixel Fold` profile with a mismatched fingerprint).
5. **Cold reboot once. Then never touch the attestation services again.**
6. Verify the log shows TEESimulator in **GENERATE** mode (not PATCH), then check
   the verdict in a PI checker.

The things that silently destroy a working setup:

- **ANY restart of `keymint` / `keystore2` / `TEESimulator`** — scripted at +8 s
  or by hand after boot → flips TEESimulator from GENERATE to PATCH mode → empty
  verdict. `08-tee-broken.sh` must contain **zero** TEESimulator restarts (older
  versions wrongly had one). **Recovery is a cold reboot, never a service restart.**
- **`autopif` overwriting `custom.pif.prop`** with a non-tokay profile.
- **PIF truncating `security_patch.txt`** to `system=202605`. `00-make-fakes.sh`
  now writes it correctly and locks it immutable; if you see the truncated form,
  cold reboot (or rewrite + `chattr +i`).

---

## 0. Prerequisites

- **Linux x86_64** host (recommended — matches the `x86_64` AVD image).
- **Docker** (for the kernel build).
- **Android SDK**: `emulator` + the
  `system-images;android-36;google_apis_playstore;x86_64` image + `adb` on PATH.
- **A valid keybox.** A TEE-class AOSP keybox. Save it as
  `device/data_adb/tricky_store/keybox.xml` (that path is `.gitignored`; see
  `keybox.xml.example`). Do **not** commit a real keybox — a public one is
  harvested and revoked by Google within hours.
  - Sanity-check it isn't revoked before blaming anything else: extract each
    certificate's serial and check it against
    `https://android.googleapis.com/attestation/status` (Google's CRL). A revoked
    keybox produces a locally-valid chain that the *server* still rejects.

## 1. Create the AVD

In Android Studio's Device Manager, create a **Pixel 9 Pro XL** AVD on the
**android-36 Google Play (x86_64)** image, then apply `device/avd-config/`:

- Ensure `config.ini` has `hw.wifi.enabled = yes`.
- Copy `advancedFeatures.ini` (`Wifi=on`, `VirtioWifi=off`) so QEMU uses
  `mac80211_hwsim` (which the custom kernel supports) instead of virtio-wifi.

## 2. Build the custom kernel

```bash
cd kernel-build
docker build -t kbuild .
# The kbuild-sources named volume is REQUIRED on macOS — the AOSP tree has files
# differing only in case, which collide on case-insensitive APFS.
docker run --rm -v "$PWD":/work -v kbuild-sources:/work/sources \
    -w /work kbuild ./scripts/build-all.sh
# → out/bzImage
```

See `kernel-build/README.md` for pinned versions, x86_64 syscall-hardening
handling, and troubleshooting.

## 3. First boot with the custom kernel

```bash
./scripts/start_avd.sh          # cold-boots with kernel-build/out/bzImage
```

The kernel has KSU-Next + SUSFS compiled in; the manager and modules aren't
installed yet. Sanity check:

```bash
adb shell 'zcat /proc/config.gz | grep -E "CONFIG_KSU=|CONFIG_KSU_SUSFS="'   # both =y
adb shell 'cat /proc/modules | grep -ciE "goldfish|hwsim|virtio_"'           # 0
```

## 4. Install the root stack

Per `device/modules.md` (exact validated URLs are in that file):

1. Install **KernelSU-Next manager** APK → launch once → confirm
   `adb shell su -c id` returns `uid=0`.
2. Install these 4 KSU modules, then reboot:
   - **SUSFS** (`susfs4ksu`, sidex15 v1.5.2+_R27)
   - **ReZygisk** (v1.0.0 release)
   - **PlayIntegrityFork** (v16)
   - **TEESimulator** / `tricky_store` (JingMatrix v3.2-67 release)

   (Vector / `zygisk_vector` is **optional** and **not required for PI** — the
   working reference has it only for unrelated LSPosed modules. Skip it.)

## 5. Apply configs + keybox + the tokay PIF profile

PlayIntegrityFork must already be installed (step 4) — its profile file is the
single source of truth that the boot scripts derive everything from.

```bash
# Pushes device/data_adb/ (the fixed boot scripts), installs your keybox at
# 0644 root:root, AND copies device/pif/custom.pif.prop into the PIF module
# (and modules_update/ so autopif can't replace it). DO NOT run autopif (see §6).
./scripts/install-device-setup.sh
```

That single command now does everything for this step (it refuses to run if PIF
isn't installed or the keybox is missing).

## 6. Cold reboot — exactly once — then verify

A **cold** boot is mandatory (a warm/snapshot boot skips the boot scripts and
TEESimulator won't land in GENERATE mode). Use the launch script, not `adb reboot`:

```bash
adb emu kill                 # fully stop the emulator
# wait for the window to close, then cold-boot with the custom kernel:
./scripts/start_avd.sh
# wait ~90s for boot + the post-fs-data.d / service.d scripts to settle
./scripts/verify-integrity.sh --trigger
```

> After boot, do **not** run `adb reboot`, `killall`, or any service restart.
> The cold boot above is the only correct way to apply changes / recover.

`verify-integrity.sh` is **read-only** (it never restarts a service). It confirms:
identity = tokay, `/vendor/build.prop` bind mount, `/proc` clean, TEESimulator
alive, keybox `0644`, and — the key one — **TEESimulator in GENERATE mode**.

Then open **Play Store** (or a Play Integrity checker) and confirm the device
verdict is populated / Play Protect shows certified.

---

## 7. THE GENERATE-VS-PATCH TRAP (read this)

This is the bug that cost the most time. Everything below is the hard-won model.

### What TEESimulator does

There is no real TEE on an emulator, so **TEESimulator** forges the
hardware-attestation chain from your `keybox.xml`. But it can forge it **two
different ways**, and only one is accepted by Google's server:

| Mode | Log signature | What it builds | Server |
|---|---|---|---|
| **GENERATE** ✅ | `Generating new attested key pair for alias: 'integrity.api.key.alias'` then `Successfully generated new certificate chain` | A brand-new leaf key + a full chain signed by your keybox → rooted in Google's attestation root. **Internally consistent.** | **Accepts** |
| **PATCH** ❌ | `Remove patched chain …` then `Cached patched certificate chain for KeyIdentifier(uid=10146, alias=integrity.api.key.alias)` | Takes the emulator's *real* keymint leaf (signed by the AVD software key) and rewrites the chain to claim the keybox root. The leaf signature no longer matches its parent. **Inconsistent.** | **Rejects → empty verdict** (a token is still returned, but with no device-integrity label) |

### What selects the mode

TEESimulator decides **once, at its own startup**, from a live "TEE functionality
check". You can see it in logcat:

```
TEESimulator: Performing TEE functionality check...
TEESimulator: TEE functionality check successful.   ← it believes a real TEE works → PATCH (BAD)
```
versus the good path on a clean emulator boot:
```
keystore2: ... Some("TEESimulator_AttestationCheck") ... Error::Km(CANNOT_ATTEST_IDS)   ← check fails → GENERATE (GOOD)
```

On a **clean cold boot**, TrickyStore's own `service.sh` launches TEESimulator
**early** — while keystore2/keymint still can't produce a hardware attestation —
so the check fails and TEESimulator correctly chooses **GENERATE**. The boot
scripts must then leave it running. `service.d/08-tee-broken.sh` only re-asserts
the immutable `tee_status.txt` / `security_patch.txt`; it does **NOT** restart
TEESimulator.

> **Corrected design (log-verified).** An earlier `08-tee-broken.sh` killed and
> relaunched TEESimulator at `boot_completed + 8s`, on the theory that one
> controlled restart was "required." That was wrong and is the exact bug that
> broke reproduction on other machines: by +8 s keymint IS ready, so the
> relaunched instance's TEE check **succeeds → PATCH → empty verdict**. The
> startup log shows it directly:
> ```
> pid A  TEE functionality check failed.      ← early instance, GENERATE (good)
> pid B  TEE functionality check successful.  ← the +8s restart, PATCH (bad)
> ```
> Fix: remove the restart entirely. There must be **zero** TEESimulator restarts.

### Why a manual restart breaks it

If, after boot, you `killall keystore2` / `killall keymint` / `killall
TEESimulator` (for example to "apply" a prop change or to clear
`CANNOT_ATTEST_IDS`), keystore2 comes back in a state where it **can** attest. The
next TEESimulator check then **succeeds** → TEESimulator flips to **PATCH** →
Google rejects the chain → empty verdict. It looks like "it randomly stopped
working." It didn't; the restart did it.

### Verify the mode (after triggering one PI check)

```bash
adb shell su -c 'logcat -d | grep -c "Generating new attested key pair for alias: .integrity.api.key.alias"'  # want >0
adb shell su -c 'logcat -d | grep -c "patched certificate chain for KeyIdentifier(uid=10146"'                 # want 0
```

---

## 8. The one rule

After the device is set up and booted, **the attestation services are
untouchable**:

- ✅ To apply ANY change (props, scripts, keybox, pif): **cold reboot.**
- ❌ Never `killall keystore2 / keymint / TEESimulator` or `setprop ctl.restart`
  on them by hand.
- ❌ Never add additional service restarts to the boot scripts.
- ❌ Never run `autopif` — it overwrites `custom.pif.prop` with a drifting profile.

If integrity is lost: **`adb reboot`** (cold). That re-runs the boot scripts and
lands TEESimulator back in GENERATE mode. Nothing else.

---

## 9. Post-mortem — what was done wrong, and the final fix

A blow-by-blow so future-you doesn't repeat it.

### Symptom
After a from-scratch setup that *looked* complete (KSU + modules + keybox + tokay
profile, all props spoofed, `/vendor/build.prop` bind-mounted, kernel correct),
Play Integrity returned **no device integrity** — repeatedly, even though a
known-good reference AVD with the *same keybox and configs* passed.

### Wrong turns (and why each was wrong)

1. **Suspected the keybox.** Pulled the certs, checked Google's CRL — **not
   revoked**. The keybox was fine all along (it's the same one the reference
   uses). Lesson: confirm-or-clear the keybox once via the CRL, then stop blaming
   it.

2. **Ran `autopif -s`.** It overwrote `custom.pif.prop` with a **felix (Pixel
   Fold)** profile carrying tokay's build ID → mismatched fingerprint. Restored
   the fixed **tokay** profile. Lesson: pin `custom.pif.prop`, never autopif.

3. **Chased `CANNOT_ATTEST_IDS` by manually restarting keymint + keystore2.**
   This is the big one. The old docs literally said "restart
   vendor.keymint-default and keystore2." Doing that *repaired* keystore2's
   attestation path just enough that **TEESimulator's TEE check started
   succeeding**, which flipped it into **PATCH mode** → empty verdict. So the
   "fix" was the cause. Every "it worked then it didn't" cycle traced back to a
   manual service restart.

4. **`chattr +i` red herring.** The immutable `tee_status.txt` produced
   `Failed to write TEE status (EPERM)` noise. `tee_status.txt` is TEESimulator's
   **output**, not its input — forcing it changes nothing about the mode. (We keep
   the immutability only because the validated reference has it; it's harmless.)

5. **Believed the scripted restart in `08-tee-broken.sh` was "required."** This
   was wrong, and chasing it cost the most time. On the original reference machine
   the +8 s restart *happened* to still land in GENERATE (timing), so it looked
   required. On a from-scratch run on another Mac, the startup log finally showed
   the truth: TrickyStore launches TEESimulator early (check **fails →
   GENERATE**), then `08`'s +8 s `pkill`+relaunch starts a *second* instance when
   keymint is ready (check **succeeds → PATCH**) → empty verdict. **The restart
   was never required — it was the bug.** Fix: delete the restart from `08`
   entirely; let TrickyStore's early GENERATE instance stand. There must be
   **zero** TEESimulator restarts anywhere.

6. **PIF truncating `security_patch.txt`.** PIF's action.sh rewrote the file's
   `system=` line to a truncated `system=202605` after `00-make-fakes.sh` wrote
   it correctly. A wrong system patch level is its own hard integrity failure.
   Fix: `00-make-fakes.sh` now `chattr +i`-locks `security_patch.txt` right after
   writing it (and `08-tee-broken.sh` re-asserts it).

### The diff that cracked it
Comparing the failing AVD to the known-good reference, everything was identical
(kernel, props, keybox hash, pif, target.txt, security_patch, keystore2 DB,
android_id, even sensors) **except the TEESimulator log line**: the reference said
`Generating new attested key pair`, the failing one said `Cached patched
certificate chain`. That single word — *generated* vs *patched* — was the whole
mystery.

### The final fix (the step that solved it)
**Remove the TEESimulator restart from `08-tee-broken.sh`, lock `security_patch.txt`
immutable, then clean cold reboot.** With no restart, TrickyStore's early
TEESimulator instance is the only one — its TEE check fails (correct on an
emulator) so it stays in GENERATE mode, builds a keybox-rooted chain, and the
verdict populates. The startup log on the fixed boot shows exactly one instance:

```
TEESimulator: TEE functionality check failed.        ← the ONE instance, GENERATE
TEESimulator: Generating new attested key pair for alias: 'integrity.api.key.alias'
```

with **no** second `TEE functionality check successful.` line. (The earlier
"final fix" claim — that a clean reboot with the scripted +8 s restart intact was
enough — held only by luck of timing on the original machine; the restart had to
be deleted for it to reproduce elsewhere.)

---

## 10. Quick troubleshooting table

| Symptom | Most likely cause | Fix |
|---|---|---|
| Empty verdict, log shows `patched certificate chain` for `integrity.api.key.alias` | TEESimulator in PATCH mode. Check the startup log: two `TEE functionality check` lines (one `failed`, one `successful`) = a restart flipped it | **Cold reboot.** Ensure `08-tee-broken.sh` has NO TEESimulator restart, and never `killall` the services by hand. After a clean boot you should see only `TEE functionality check failed.` (one instance). |
| `security_patch.txt` shows `system=202605` (truncated) | PIF's action.sh corrupted it after boot | `00-make-fakes.sh` now writes it correctly and `chattr +i`-locks it; cold reboot. Manually: `chattr -i`, rewrite all three lines `=YYYY-MM-DD`, `chattr +i`. |
| `CANNOT_ATTEST_IDS` spam, identity still `emu64x` | prop spoof / build.prop bind didn't apply before keymint | Cold reboot (scripts run in order). Don't `killall keymint`. |
| `MODEL=Pixel Fold` / `DEVICE=felix` | `autopif` overwrote the profile | Re-copy tokay `device/pif/custom.pif.prop`, cold reboot, never autopif. |
| Verdict empty but chain is GENERATE + not revoked | device not certified yet / no GSF android_id | Ensure Wi-Fi is connected; let it check in; cold reboot. |
| `TEESimulator not running` | daemon died | `05-tee-watchdog.sh` relaunches it; if not, cold reboot. |
| Works on reference, fails on yours, configs identical | keybox `0600` (unreadable by injected TEESimulator) | `chmod 644` the keybox (install script now does this), cold reboot. |

## Layout reference

```
kernel-build/        Docker + scripts that build the custom kernel
device/
  data_adb/          → pushed to /data/adb on the device
    post-fs-data.d/  prop spoofs + bind mounts (run before zygote)
    service.d/       tee-watchdog, tee-broken (re-assert immutable, NO restart), display, wlan0
    tricky_store/    target/security_patch/tee_status + keybox (gitignored, 0644)
    susfs4ksu/       SUSFS rule files
    avd-fake/        fake /proc/* + /vendor/build.prop contents
  pif/               PlayIntegrityFork profile (Pixel 9 / tokay) — pinned, no autopif
  avd-config/        host-side config.ini + advancedFeatures.ini templates
  modules.md         prerequisite root modules + exact download URLs
scripts/
  start_avd.sh             cold-boot the AVD with the custom kernel
  install-device-setup.sh  push device/data_adb + keybox (0644) to a rooted AVD
  verify-integrity.sh      READ-ONLY health check incl. GENERATE-vs-PATCH mode
docs/
  INTEGRITY_CHAIN.md   why each layer matters (incl. Layer 1b: the trap)
  REPRODUCTION.md      this file
```
