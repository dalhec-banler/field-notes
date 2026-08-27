# Field Notes

A local-first field journal for people who own and actively manage land.
Walk the property, photograph plants, record what you see. Every record is
a point on a map with a timestamp, a photo, an optional species, notes, and
a voice note. Plantings are tracked from cutting collection through
propagation to survival over years; springs, guzzlers, erosion and other
features get condition histories; photo points guide you back to the same
frame with a ghost overlay.

The data lives on the phone. It works with the radio off. Nothing leaves
the device without an explicit action, and a full export reconstructs the
whole dataset in open formats (SQLite, CSV, GeoJSON, KML, JPEG with EXIF
GPS, m4a).

## Layout

- `docs/SPEC.md` — the build spec. §4 (data model) is the contract.
- `DECISIONS.md` — decision log; the only place spec deviations are recorded.
- `docs/AUDIT-2026-08-26.md`, `docs/SPEC-GAP-2026-08-26.md` — audit findings
  and scope-vs-spec status.
- `app/` — the Flutter project (`field_notes`).

## Build (Android)

Requires Flutter 3.47+, Android SDK, and **JDK 21** (`flutter config
--jdk-dir /opt/homebrew/opt/openjdk@21` on macOS; `maplibre_gl` needs
source level 21).

```
cd app
flutter pub get
flutter test
flutter build apk --release      # needs android/key.properties (gitignored)
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

Offline basemaps: on the map, frame an area and tap **⌗ Capture area**
(downloads from the Protomaps planet build), or import a `.pmtiles` file
under Settings → Offline maps. `docs/basemap/` is gitignored.

## Stack

Flutter + drift over SQLite · `maplibre_gl` with PMTiles/MBTiles served
from a loopback `shelf` server · `geolocator` behind a single-owner
`LocationHub` · `camera`, `record` + `speech_to_text` · `cryptography`
(Argon2id + XChaCha20-Poly1305) for encrypted backups with a BIP-39
recovery phrase.
