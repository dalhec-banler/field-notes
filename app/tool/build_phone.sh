#!/usr/bin/env bash
# Build the phone APK and say how it stands against HEAD.
#
# Bumps nothing. A release build signed with android/key.properties when
# that file is present (the phone's keystore), debug-signed when it is not.
# Prints the APK's modification time next to the HEAD commit's, which is
# what tool/install.sh checks before it will install.
#
#   tool/build_phone.sh            # from app/ or anywhere
set -euo pipefail

cd "$(dirname "$0")/.."

APK=build/app/outputs/flutter-apk/app-release.apk

mtime() { stat -f %m "$1" 2>/dev/null || stat -c %Y "$1"; }
when()  { date -r "$1" '+%Y-%m-%d %H:%M:%S %Z' 2>/dev/null || date -d "@$1" '+%Y-%m-%d %H:%M:%S %Z'; }

if [ -f android/key.properties ]; then
  echo "signing: android/key.properties (release keystore)"
else
  echo "signing: debug keystore (android/key.properties absent)"
fi

flutter build apk --release

apk_time=$(mtime "$APK")
head_time=$(git log -1 --format=%ct)
head_sha=$(git rev-parse --short HEAD)

echo
echo "APK   $APK"
echo "      $(when "$apk_time")"
echo "HEAD  $head_sha  $(when "$head_time")"
if [ -n "$(git status --porcelain)" ]; then
  echo "tree  DIRTY — this APK carries uncommitted changes"
else
  echo "tree  clean"
fi
if [ "$apk_time" -ge "$head_time" ]; then
  echo "APK is newer than HEAD: install.sh will take it."
else
  echo "APK is OLDER than HEAD: install.sh will refuse it."
fi
