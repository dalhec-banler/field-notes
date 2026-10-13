# tool/

Scripts for getting a build onto the phone without guessing, and the
on-device smoke suite. Run them from `app/` (they `cd` there themselves).

## build_phone.sh

```
tool/build_phone.sh
```

Runs `flutter build apk --release` and bumps nothing. Signs with the
keystore when `android/key.properties` is present, with the debug key when
it is not (`build.gradle.kts` makes that choice). Ends by printing the
APK's modification time against the HEAD commit's, and whether the tree
is clean — the two things `install.sh` will check.

## install.sh

```
tool/install.sh                 # one device attached
tool/install.sh 54221FDAP001N4  # or ANDROID_SERIAL=... tool/install.sh
```

Installs `build/app/outputs/flutter-apk/app-release.apk` with
`adb install -r` (data kept). Before it does, it prints the phone's
installed `versionName`, `versionCode` and `lastUpdateTime`, and refuses
outright when:

- the working tree is dirty — the APK may not match any commit;
- the APK is older than the HEAD commit — a stale build;
- the phone's installed `versionCode` is higher than the APK's — a
  downgrade. Bump `version:` in `pubspec.yaml` and rebuild.

It prints the same three fields again after the install. The APK's own
version is read with `aapt2` when an Android SDK is on `ANDROID_HOME`,
else from `pubspec.yaml`.

## Smoke suite

The same cases run on the host and on a device; the device run is the
one that proves the phone's sqlite, filesystem and codecs behave.

```
flutter test test/smoke                          # host, seconds
flutter test integration_test -d emulator-5554   # device
```

Boot the emulator first: `flutter emulators --launch fieldnotes`. Do not
point the device run at a phone that holds real records — it installs
the test build under the app's package id. Every write goes to a
temporary directory through a replaced path provider; the production
store is never opened.

Cases, each asserting observation / media / media_links counts after the
step: capture with a photo, capture with a voice note (the link role that
once failed the schema CHECK), capture without GPS (`gps_accuracy_m = -1`),
edit notes and type, soft delete then UNDO-erase, backup to a folder and
restore into a fresh store (plain and encrypted), and a v9 database
opening at the current schema with its rows intact.

## Also here

- `external_audit_test.dart`, `relay_e2e_test.dart` — one-off harnesses
  from earlier audits; see the headers in each.
