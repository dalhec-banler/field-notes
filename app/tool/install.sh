#!/usr/bin/env bash
# Install the built release APK on the phone — and refuse when it would
# put the wrong build there.
#
# Refuses when:
#   (a) the working tree is dirty (the APK may not match any commit),
#   (b) the APK is older than the HEAD commit (stale build),
#   (c) the phone already runs a HIGHER versionCode (a downgrade would be
#       refused by Android anyway, or worse, succeed with -d and lose data).
#
# Prints the installed package's versionName / versionCode / lastUpdateTime
# before and after. Installs with `adb install -r` (keep data).
#
#   tool/install.sh [serial]        # or ANDROID_SERIAL=... tool/install.sh
set -euo pipefail

cd "$(dirname "$0")/.."

PKG=io.nativeplanet.field_notes
APK=build/app/outputs/flutter-apk/app-release.apk
SERIAL="${1:-${ANDROID_SERIAL:-}}"

die() { echo "refusing: $*" >&2; exit 1; }
mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
when()  { date -r "$1" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H:%M:%S %Z'; }

# --- which phone ---------------------------------------------------------
if [ -z "$SERIAL" ]; then
  devices=()
  while IFS= read -r d; do devices+=("$d"); done \
    < <(adb devices | awk 'NR > 1 && $2 == "device" { print $1 }')
  case ${#devices[@]} in
    0) die "no device attached (adb devices shows none ready)" ;;
    1) SERIAL=${devices[0]} ;;
    *) printf '%s\n' "${devices[@]}" >&2
       die "more than one device attached; pass a serial or set ANDROID_SERIAL" ;;
  esac
fi
ADB=(adb -s "$SERIAL")

# --- (a) clean tree ------------------------------------------------------
if [ -n "$(git status --porcelain)" ]; then
  git status --short >&2
  die "working tree is dirty — commit or discard first, then rebuild"
fi

# --- (b) APK newer than HEAD --------------------------------------------
[ -f "$APK" ] || die "no APK at $APK — run tool/build_phone.sh"
apk_time=$(mtime "$APK")
head_time=$(git log -1 --format=%ct)
if [ "$apk_time" -lt "$head_time" ]; then
  die "APK ($(when "$apk_time")) is older than HEAD ($(when "$head_time")) — run tool/build_phone.sh"
fi

# --- APK version ---------------------------------------------------------
# aapt2 from the newest build-tools when the SDK is around; otherwise the
# pubspec, which is what a clean-tree build was made from.
sdk="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
aapt2=""
if [ -n "$sdk" ] && [ -d "$sdk/build-tools" ]; then
  aapt2=$(ls -d "$sdk"/build-tools/*/aapt2 2>/dev/null | sort -V | tail -1 || true)
fi
if [ -n "$aapt2" ] && [ -x "$aapt2" ]; then
  badging=$("$aapt2" dump badging "$APK")
  apk_vc=$(sed -n "s/.*versionCode='\([0-9]*\)'.*/\1/p" <<<"$badging" | head -1)
  apk_vn=$(sed -n "s/.*versionName='\([^']*\)'.*/\1/p" <<<"$badging" | head -1)
  apk_pkg=$(sed -n "s/.*package: name='\([^']*\)'.*/\1/p" <<<"$badging" | head -1)
  [ "$apk_pkg" = "$PKG" ] || die "APK is $apk_pkg, not $PKG"
  apk_src="aapt2"
else
  ver=$(sed -n 's/^version:[[:space:]]*//p' pubspec.yaml | head -1)
  apk_vn=${ver%%+*}
  apk_vc=${ver##*+}
  apk_src="pubspec.yaml"
fi
[[ "$apk_vc" =~ ^[0-9]+$ ]] || die "could not read the APK's versionCode"

# --- phone version -------------------------------------------------------
phone_state() {
  local dump
  dump=$("${ADB[@]}" shell dumpsys package "$PKG" 2>/dev/null || true)
  phone_vc=$(sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' <<<"$dump" | head -1)
  phone_vn=$(sed -n 's/.*versionName=\(.*\)$/\1/p' <<<"$dump" | head -1 | tr -d '\r')
  phone_updated=$(sed -n 's/.*lastUpdateTime=\(.*\)$/\1/p' <<<"$dump" | head -1 | tr -d '\r')
}
show() {
  if [ -z "${phone_vc:-}" ]; then
    echo "  $PKG: not installed"
  else
    echo "  $PKG: versionName=$phone_vn versionCode=$phone_vc lastUpdateTime=$phone_updated"
  fi
}

echo "device $SERIAL  ($("${ADB[@]}" shell getprop ro.product.model | tr -d '\r'))"
echo "apk    versionName=$apk_vn versionCode=$apk_vc  (from $apk_src, built $(when "$apk_time"), HEAD $(git rev-parse --short HEAD))"
echo "before:"
phone_state; show

# --- (c) never downgrade -------------------------------------------------
if [ -n "${phone_vc:-}" ] && [ "$phone_vc" -gt "$apk_vc" ]; then
  die "phone runs versionCode $phone_vc, APK is $apk_vc — bump pubspec.yaml and rebuild"
fi

# --- install -------------------------------------------------------------
"${ADB[@]}" install -r "$APK"

echo "after:"
phone_state; show
