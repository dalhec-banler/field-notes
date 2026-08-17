# Field Notes — Decision Log

Decisions made against `docs/SPEC.md` (Field Station Build Spec v0.1). Newest at the bottom.
Spec §9 open questions are resolved or deferred here.

## 2026-08-14 — Kickoff decisions (Austin)

### D-001 · App name: **Field Notes**
Folder `~/Desktop/Field Notes`, Flutter project name `field_notes`. Alternatives
(Rootstock, Groundtruth, Steward) were offered and declined. "Field Station" was
avoided — collides with Shorts Resort Field Station.

### D-002 · Species seed: broader regional list, 41 favorited (spec §9.1)
Ship Edwards Plateau / Lampasas Cut Plain natives plus the usual invasives as the
seed library, with the SFS 41-species working palette pre-marked `is_favorite = 1`
so quick-pick surfaces them first.

### D-003 · Multi-property UI from day one (spec §9.5 — overrides spec lean)
Not just multiple owned properties: Austin wants to track fields, public land, and
offsite candidate-species collection sites as first-class places. UI ships with a
property switcher from v1.

### D-004 · Schema extension: `properties.land_tenure` (deviation from §4 contract, approved)
New column: `land_tenure TEXT NOT NULL DEFAULT 'owned'
CHECK (land_tenure IN ('owned','leased','public','collection_site','other'))`.
Non-owned tenures skip boundary/acreage/membership requirements in the UI;
capture and mapping work identically everywhere. `source_plants` may live on any
property regardless of tenure (complements `is_on_property`/`origin_notes`).
This is the only approved deviation from the §4 contract so far.

### D-005 · Tag codes: free text with auto-suggest (spec §9.2)
Free-text `tag_code`, with the UI suggesting the next code in the user's last-used
pattern (e.g. `SFS-BW-041`). No enforced format, no QR scanner in v1 — schema is
unchanged either way, so scanning can be added later.

### Deferred (decide at Milestone 4)
- §9.3 Naturalist suggestion notifications vs. silent review queue.
- §9.4 Guest-link default (spec default stands for now: fuzzed, 30-day expiry).

## 2026-08-17 — Build-out decisions (made autonomously, flag if wrong)

### D-006 · Offline basemap distribution: user-supplied URL for v1
The in-app downloader accepts any direct `.pmtiles` URL (resumable). On-device
bbox extraction from build.protomaps.com was considered and deferred — it means
implementing a PMTiles v3 archive *writer* in Dart. Revisit if the URL flow
proves too technical for non-Austin users.

### D-007 · Photo point anchoring: first visit sets position/bearing/reference
Rather than asking the user to type a bearing, the first captured frame anchors
the point: GPS position, compass bearing, and the reference image are taken
from that visit. Compass is tilt-compensated accelerometer+magnetometer
(sensors_plus), smoothed; no rotation-vector dependency.

### D-008 · Track raw points are discarded after save
Spec §4.13 says retain raw points "only for the active track" — implemented
literally: on stop, the simplified LineString (Douglas-Peucker 5 m) plus total
distance is stored and `track_points` rows for that track are deleted.

### D-009 · Release keystore location
`~/.keystores/fieldnotes-release.jks`, password in
`~/.keystores/fieldnotes-release.pass` (plaintext on this machine, outside the
repo). `android/key.properties` is gitignored. LOSING THE KEYSTORE MEANS
FUTURE APKS CANNOT UPDATE IN PLACE — back these two files up.
