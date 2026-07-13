#!/usr/bin/env bash
# Verify the integrity stack on a running, rooted AVD.
#
# By default this is READ-ONLY (getprop/logcat/mount). It never restarts a
# service — doing so would itself break the verdict (docs/INTEGRITY_CHAIN.md
# "Layer 1b").
#
# The make-or-break check is whether TEESimulator forged the integrity key in
# GENERATE mode (good) or PATCH mode (bad). That only shows up in logcat AFTER a
# Play Integrity request has happened. So this script can TRIGGER one for you:
#
#   ./scripts/verify-integrity.sh --trigger    # fire a PI check, then verify
#   ./scripts/verify-integrity.sh              # verify only (you trigger a check)
#
# Other:
#   ADB="adb -s emulator-5554" ./scripts/verify-integrity.sh --trigger

set -uo pipefail
ADB="${ADB:-adb}"
TRIGGER=0
[ "${1:-}" = "--trigger" ] && TRIGGER=1
pass(){ printf '  \033[32m✓\033[0m %s\n' "$*"; }
fail(){ printf '  \033[31m✗\033[0m %s\n' "$*"; FAILED=1; }
note(){ printf '    %s\n' "$*"; }
sh(){ $ADB shell "su -c \"$1\"" 2>/dev/null | tr -d '\r'; }
FAILED=0

# The EXPECTED device comes from the active profile (single source of truth),
# so this works for any profile, not just tokay.
WANT=$(sh 'sed -n "s/^DEVICE=//p" /data/adb/avd-fake/profile.env 2>/dev/null | tr -d "\"" | head -n1')
[ -z "$WANT" ] && WANT=$(sh 'sed -n "s/^DEVICE=//p" /data/adb/modules/playintegrityfix/custom.pif.prop 2>/dev/null | head -n1')
[ -z "$WANT" ] && WANT=tokay

echo "== Identity (every namespace must = profile device '$WANT', not emu64x) =="
dev=$(sh 'getprop ro.product.vendor.device')
[ "$dev" = "$WANT" ] && pass "ro.product.vendor.device = $WANT" || fail "ro.product.vendor.device = '$dev' (want $WANT)"
okp=1
for p in odm product system_ext system_dlkm vendor_dlkm; do
  v=$(sh "getprop ro.product.$p.device"); [ "$v" = "$WANT" ] || { okp=0; fail "ro.product.$p.device = '$v' (want $WANT)"; }
done
[ "$okp" = "1" ] && pass "all per-partition device props = $WANT"
# Consistency: every fingerprint namespace must agree (the old 08-vs-01 bug).
fps=$(sh 'for n in "" .vendor .system .product .odm; do getprop ro$n.build.fingerprint; done | sort -u | grep .')
nfp=$(printf '%s\n' "$fps" | grep -c .)
[ "$nfp" = "1" ] && pass "all build.fingerprints agree ($(printf '%s' "$fps" | head -c 60)…)" || { fail "fingerprints DISAGREE across namespaces ($nfp distinct):"; printf '%s\n' "$fps" | sed 's/^/      /'; }
vb=$(sh 'grep "^ro.product.vendor.device" /vendor/build.prop')
echo "$vb" | grep -q "$WANT" && pass "/vendor/build.prop bind-mounted ($WANT)" || fail "/vendor/build.prop not spoofed: $vb"

echo "== /proc + devicetree clean =="
[ "$(sh 'grep -m1 implementer /proc/cpuinfo' | grep -o '0x41')" = "0x41" ] && pass "cpuinfo implementer 0x41" || fail "cpuinfo implementer not 0x41"
# NOTE: pass each file through cat first; 'grep -c' over multiple files prints
# 'file:count' per file which broke the old check (cosmetic false positive).
n=$(sh 'cat /proc/cpuinfo /proc/version 2>/dev/null | grep -ic ranchu')
[ "${n:-1}" = "0" ] && pass "no 'ranchu' in cpuinfo/version" || fail "'ranchu' leaks in /proc ($n)"

echo "== TEESimulator alive + keybox readable =="
ts=$(sh 'pidof TEESimulator'); [ -n "$ts" ] && pass "TEESimulator running (pid $ts)" || fail "TEESimulator NOT running"
kb=$(sh 'ls -l /data/adb/tricky_store/keybox.xml'); echo "$kb" | grep -q 'rw-r--r--' && pass "keybox.xml is 0644 (readable by injected TEESimulator)" || { fail "keybox.xml perms wrong:"; note "$kb"; note "must be 0644 — chmod 644 it and cold reboot"; }
# security_patch.txt must be per-component AND match the profile patch.
wantpatch=$(sh 'sed -n "s/^SECURITY_PATCH=//p" /data/adb/avd-fake/profile.env 2>/dev/null | tr -d "\"" | head -n1')
sp=$(sh 'cat /data/adb/tricky_store/security_patch.txt' | head -1)
if echo "$sp" | grep -q "^system="; then
  [ -z "$wantpatch" ] && pass "security_patch.txt keyed per-component ($sp)" || \
  { echo "$sp" | grep -q "$wantpatch" && pass "security_patch.txt matches profile ($wantpatch)" || fail "security_patch.txt=$sp but profile patch=$wantpatch (must match)"; }
else
  fail "security_patch.txt first line='$sp' — must be 'system=YYYY-MM-DD' (NOT all=)"
fi

echo "== Device registration (Play Protect needs a GSF android_id) =="
aid=$(sh 'sqlite3 /data/data/com.google.android.gsf/databases/gservices.db "select value from main where name=\"android_id\";" 2>/dev/null')
if [ -n "$aid" ] && [ "$aid" != "0" ]; then pass "GSF android_id present ($aid) — device is checked in"
else note "No GSF android_id yet (sqlite3 may be absent; not fatal). If the verdict"; note "stays empty with GENERATE mode, the device isn't certified yet — ensure"; note "Wi-Fi is connected, wait a few minutes, then cold reboot."; fi

if [ "$TRIGGER" = "1" ]; then
  echo "== Triggering a fresh Play Integrity check (Play Store) =="
  sh 'am force-stop com.android.vending; rm -rf /data/data/com.google.android.gms/files/droidguard/* 2>/dev/null; pm clear com.android.vending >/dev/null 2>&1; sleep 2; logcat -c; monkey -p com.android.vending -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1' >/dev/null
  note "launched Play Store; waiting 30s for the PI flow..."
  sleep 30
fi

echo "== Attestation MODE (the make-or-break check) =="
gen=$(sh 'logcat -d | grep -c "Generating new attested key pair for alias: .integrity.api.key.alias"')
pat=$(sh 'logcat -d | grep -c "patched certificate chain for KeyIdentifier(uid=10146"')
caid=$(sh 'logcat -d | grep -c CANNOT_ATTEST_IDS')
tok=$(sh 'logcat -d | grep -c "Integrity key attestation record generated successfully"')
if [ "${gen:-0}" -gt 0 ] && [ "${pat:-0}" -eq 0 ]; then
  pass "TEESimulator in GENERATE mode for integrity.api.key.alias ($gen gen / $pat patch)"
  [ "${tok:-0}" -gt 0 ] && pass "integrity token issued ($tok)" || note "token not seen yet — give Play Store a few more seconds"
elif [ "${pat:-0}" -gt 0 ]; then
  fail "TEESimulator in PATCH mode ($pat patch) — verdict will be EMPTY."
  note "Cause: an out-of-band restart of keymint/keystore2/TEESimulator flipped it."
  note "Fix:   adb reboot  (clean COLD boot). NEVER killall those services by hand."
else
  note "No integrity.api.key.alias activity captured."
  note "Re-run WITH a trigger:  ./scripts/verify-integrity.sh --trigger"
fi
note "CANNOT_ATTEST_IDS lines this window: ${caid:-?} (a few at early boot are ok)"

echo
if [ "$FAILED" = "0" ]; then printf '\033[32mStructural checks passed.\033[0m If MODE=GENERATE + token issued but a checker still shows empty, it is certification (see registration note) — connect Wi-Fi, wait, cold reboot.\n'
else printf '\033[31mSome checks failed — see above.\033[0m If MODE is PATCH: cold reboot. Never restart services by hand.\n'; fi
