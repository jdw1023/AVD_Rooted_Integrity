# Why this passes Play Integrity — the chain end to end

Goal: a rooted Pixel-class AVD that returns **`MEETS_STRONG_INTEGRITY`** with a
full Labels list (`MEETS_BASIC_INTEGRITY`, `MEETS_DEVICE_INTEGRITY`,
`MEETS_STRONG_INTEGRITY`) and shows **Play Protect certified**. No StrongBox
hardware is required: TEESimulator forges a complete attestation chain from your
own keybox, rooted in Google's attestation root, so the verdict reaches **strong**
integrity on a pure emulator — provided the forge stays in GENERATE mode and no
emulator tell leaks (the rest of this document).

The verdict is produced by DroidGuard inside `com.google.android.gms.unstable`.
It fails if **any** of these layers leaks: a forged attestation chain that
doesn't validate, an emulator fingerprint in props / `/proc`, or a visible root
module. All three layers have to hold simultaneously.

## Layer 1 — a hardware attestation chain that validates

`keystore2` → `vendor.keymint-default` normally produces an attestation chain
rooted in real TEE hardware. On an emulator there is no such hardware, so:

- **TEESimulator (`tricky_store`)** intercepts the keystore attestation request
  and forges the chain using the keys in `/data/adb/tricky_store/keybox.xml`.
- `tee_status.txt` is set to `tee_broken=true` and made immutable (`chattr +i`)
  — written first by `00-make-fakes.sh` / present from install, and re-asserted
  by `service.d/08-tee-broken.sh` — so the daemon takes the software-forge path.
- `security_patch.txt` is keyed per-component (`system=`/`boot=`/`vendor=`), all
  set to the profile's patch level so the forged chain's claimed patch matches the
  spoofed `ro.*.security_patch` props. It's written **and pinned immutable** by
  `00-make-fakes.sh` because PIF's action.sh otherwise truncates the `system=`
  line (observed as `system=202605`), which is a hard integrity failure.
- `service.d/05-tee-watchdog.sh` relaunches TEESimulator **only if it has died** —
  if the daemon is down when a PI request lands, keystore2 falls through to raw
  software keymint with no keybox and the verdict comes back **empty**. (Note: a
  watchdog relaunch mid-session would land in PATCH mode; in practice the daemon
  doesn't die, but if integrity is ever lost, the fix is a clean cold reboot.)

## Layer 2 — no emulator fingerprint in identity props

This is the layer that produces the **`CANNOT_ATTEST_IDS`** failure if it leaks.
keymint reads the attestation IDs not just from the top-level `ro.product.*`
props, but from **per-partition props** (`ro.product.<vendor|odm|product|
system_dlkm|system_ext|vendor_dlkm>.*`) **and from the on-disk
`/vendor/build.prop` file directly**. PIF only spoofs the top-level props, so
the per-partition values and the file contents still leak `emu64x` /
`sdk_gphone64_x86_64`. keymint compares the caller's requested IDs against its
cached IDs and throws `CANNOT_ATTEST_IDS` on any mismatch.

The fix is layered:

- `post-fs-data.d/01-avd-prop-spoof.sh` — sets the Pixel 9 (`tokay`) identity
  across **all** partition prop namespaces, clears `ro.kernel.qemu*` /
  `ro.boot.qemu*`, and sets verified-boot props (`locked`, `green`, `enforcing`).
- `post-fs-data.d/08-partition-props.sh` — re-asserts every per-partition
  `ro.product.<partition>.*` (belt-and-suspenders against init re-setting them).
- `post-fs-data.d/09-buildprop-bind.sh` — bind-mounts `avd-fake/vendor_build.prop`
  over `/vendor/build.prop` (and the odm one) so the **file** keymint reads
  matches the props. This is the piece that actually clears `CANNOT_ATTEST_IDS`.
- `post-fs-data.d/04-prop-sweep.sh` + `06-bootloader-safe.sh` — delete every
  remaining `qemu.*` / `ranchu*` / `goldfish*` / `ro.boottime.*emulator*` prop.

keymint caches the IDs at startup, so the spoofs must be in place before keymint
reads them. The boot scripts handle this. **The correct way to apply changes is a
clean COLD REBOOT — never `killall keymint`/`keystore2` by hand.** See the
"generate-vs-patch trap" below for why a manual restart actively *breaks* the
verdict.

> Diagnosing: `adb shell su -c 'logcat -d | grep CANNOT_ATTEST_IDS'`. If any
> appear, the chain rebuild never even starts. Verify
> `getprop ro.product.vendor.device` → `tokay` (not `emu64x`) and
> `grep "^ro.product" /vendor/build.prop` shows the spoofed values. The recovery
> is **cold reboot**, then re-check.

## Layer 1b — TEESimulator must run in GENERATE mode, not PATCH mode (the trap)

This is the subtlest failure, and the one that cost the most time. Once the
attestation chain is forged at all, there are still **two ways** TEESimulator can
forge it, and only one is accepted by Google's server:

| Mode | Log signature | Chain it produces | Server result |
|---|---|---|---|
| **GENERATE** ✅ | `Generating new attested key pair for alias: 'integrity.api.key.alias'` → `Successfully generated new certificate chain` | A fresh leaf key + a complete chain signed by your keybox (rooted in Google's attestation root). Internally consistent. | **Accepted** — verdict populated |
| **PATCH** ❌ | `Remove patched chain …` → `Cached patched certificate chain for KeyIdentifier(uid=10146, alias=integrity.api.key.alias)` | The emulator's *real* keymint leaf (signed by the AVD's software key) with the chain rewritten to claim the keybox root. The leaf signature no longer matches the patched parent. | **Rejected** — empty / "no integrity" verdict, even though a token is still issued |

TEESimulator chooses the mode **once**, from a live "TEE functionality check" it
runs at its own startup:

```
TEESimulator: Performing TEE functionality check...
TEESimulator: TEE functionality check successful.   ← thinks the TEE works → PATCH (bad)
```
vs. (the good path, on a clean emulator boot)
```
TEESimulator_AttestationCheck … Error::Km(CANNOT_ATTEST_IDS)   ← check fails → GENERATE (good)
```

TrickyStore's own `service.sh` launches TEESimulator **early** (post-fs-data
era), while keystore2/keymint still can't produce a real hardware attestation —
so the check **fails** and TEESimulator correctly picks **GENERATE**. The boot
scripts must then leave it alone. `service.d/08-tee-broken.sh` only re-asserts
`tee_status.txt = tee_broken=true` (immutable) and re-pins `security_patch.txt`;
it does **NOT restart TEESimulator**.

> **The restart is the trap — proven by the startup log.** An earlier version of
> `08-tee-broken.sh` killed and relaunched TEESimulator at `boot_completed + 8s`,
> believing that restart was "required." It is the opposite: by 8 s into boot,
> keymint IS ready, so the relaunched instance's TEE check **succeeds → PATCH**.
> The log shows both instances plainly:
> ```
> pid A  TEE functionality check failed.      ← early instance, GENERATE (good)
> pid B  TEE functionality check successful.  ← the +8s restart, PATCH (bad)
> ```
> The fix: **never restart TEESimulator**. Let TrickyStore's early instance stand.
> (Older docs here said the single restart was required — that was wrong; this is
> the corrected, log-verified design.)

Any restart of `keystore2` / `keymint` / `TEESimulator` — whether scripted at
+8s, or done by hand after boot while chasing `CANNOT_ATTEST_IDS` — re-rolls the
TEE check when keymint is ready, flips TEESimulator to **PATCH**, and integrity is
lost until the next clean cold reboot. This was the root cause of every "it worked, then it
didn't" cycle.

**Verify the mode after boot:**
```bash
adb shell su -c 'logcat -d | grep -c "Generating new attested key pair for alias: .integrity.api.key.alias"'  # want >0
adb shell su -c 'logcat -d | grep -c "patched certificate chain for KeyIdentifier(uid=10146"'                 # want 0
```

## Layer 3 — `/proc/*` and devicetree don't say "ranchu/goldfish"

Apps (and DroidGuard) also read `/proc/cpuinfo`, `/proc/version`,
`/proc/cmdline`, `/proc/modules`, and `/sys/firmware/devicetree/base/compatible`.

- The **kernel build** already filters `/proc/modules` and spoofs
  `/proc/cpuinfo` MIDR at the source level (see `kernel-build/`).
- On-device, `post-fs-data.d/07-procbind-safe.sh` bind-mounts the
  `avd-fake/{cpuinfo,version,cmdline,modules}` and `dt_compatible` fakes, and
  `02-avd-deeper-spoof.sh` adds SUSFS `add_open_redirect` for the same `/proc/*`
  paths (redirect survives in more contexts than a bind mount).
- `/dev/goldfish_*` nodes are deliberately **left visible** — hiding them breaks
  graphics bringup (`mapper.ranchu` needs `goldfish_address_space`). Only the
  `/dev/qemu_*` nodes are `sus_path`-hidden.

## Layer 4 — the root stack itself is invisible

If `gms.unstable` can see the strings `playintegrityfix`, `zygisk_vector`,
`rezygisk`, or `tricky_store` in its own `/proc/self/maps`, that alone fails PI.

- `02-avd-deeper-spoof.sh` runs SUSFS `add_sus_map` on each injected `.so`
  (matching `susfs4ksu/sus_map.txt`).
- `00-zygisk-sepolicy.sh` applies the SELinux ALLOW rules ReZygisk needs so
  zygote can `dlopen` libzygisk.so from `/data/adb` (without it, zygote gets
  silent EACCES and the Zygisk monitor reports "Zygote crashed").
- SUSFS `config.sh` hides KSU/SUSFS symbols and spoofs `uname`.

## Layer 5 — networking looks real

`service.d/10-wlan0-virtwifi.sh` brings up `wlan0` by wrapping `eth0` with the
`virt_wifi` kernel module and connects to the `VirtWifi` open network. A device
with no Wi-Fi interface at all is itself a weak emulator signal, and some flows
expect a connected `wlan0`. Requires `hw.wifi.enabled=yes` in the AVD's
`config.ini` and `VirtioWifi=off` in `advancedFeatures.ini` (so QEMU uses
`mac80211_hwsim`, which the custom kernel supports).

## Order of operations summary

```
boot
 ├─ kernel (KSU + SUSFS + /proc spoofs compiled in)
 ├─ post-fs-data.d/  (before zygote)
 │    00 make-fakes (parse profile -> profile.env; generate vendor/odm build.prop
 │       from the LIVE partition; dt_compatible; security_patch.txt + lock)
 │    00 zygisk-sepolicy → 01 prop-spoof (all identity, from profile.env)
 │    02 deeper-spoof (susfs redirects/maps) → 04 prop-sweep
 │    07 procbind → 09 buildprop-bind
 │  TrickyStore service.sh launches TEESimulator EARLY -> GENERATE mode
 ├─ zygote starts → ReZygisk injects PIF
 └─ service.d/ (after boot_completed)
      05 tee-watchdog (relaunches TEESimulator ONLY if it has died)
      08 tee-broken (re-assert immutable tee_status + security_patch; NO restart)
      09 display (match Pixel metrics)
      10 wlan0-virtwifi (bring up Wi-Fi)
```

See the `CANNOT_ATTEST_IDS` reasoning above for the most common *startup* failure
path, **Layer 1b (the generate-vs-patch trap)** for the most common *"it broke
after I poked it"* failure, and `REPRODUCTION.md` for step-by-step setup plus the
full post-mortem.

## The one rule that prevents 90% of grief

After the device is booted and set up, treat the attestation services as
**untouchable**:

- ✅ To apply any change (props, scripts, keybox): **cold reboot.**
- ❌ Never `killall keystore2`, `killall keymint`, `killall TEESimulator`, or
  `setprop ctl.restart …` on them by hand. A restart re-rolls TEESimulator's TEE
  check (which by then succeeds) and flips it from GENERATE to PATCH → empty verdict.
- ❌ Never add a TEESimulator restart to the boot scripts. TrickyStore's own
  `service.sh` already starts it early, in GENERATE mode; `08-tee-broken.sh` must
  only re-assert the immutable `tee_status.txt` / `security_patch.txt`, never restart.
