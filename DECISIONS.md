# Field Notes — Decision Log

Decisions made against `docs/SPEC.md` (Field Station Build Spec v0.1). Newest at the bottom.
Spec §9 open questions are resolved or deferred here.

## 2026-08-14 — Kickoff decisions (Austin)

### D-001 · App name: **Field Notes**
Folder `~/Desktop/Field Notes`, Flutter project name `field_notes`. Alternatives
(Rootstock, Groundtruth, Steward) were offered and declined. "Field Station" was
avoided — collides with Shorts Resort Field Station. 
Field notes is fine

### D-002 · Species seed: broader regional list, 41 favorited (spec §9.1)
Ship Edwards Plateau / Lampasas Cut Plain natives plus the usual invasives as the
seed library, with the SFS 41-species working palette pre-marked `is_favorite = 1`
so quick-pick surfaces them first.

We need to expand how we handle these databases, it would be nice if the user could select their region and we pull from a usda database or local resource to build the lists, user can then manually add them based on what htey find on their property using the AI tool. I dont want people to have to upload their lists, but that should be an option, id rather people be able to use GPS to have our app source databases to scrape for their own lists. 

### D-003 · Multi-property UI from day one (spec §9.5 — overrides spec lean)
Not just multiple owned properties: Austin wants to track fields, public land, and
offsite candidate-species collection sites as first-class places. UI ships with a
property switcher from v1. YES DO THIS!!!!

### D-004 · Schema extension: `properties.land_tenure` (deviation from §4 contract, approved)
New column: `land_tenure TEXT NOT NULL DEFAULT 'owned'
CHECK (land_tenure IN ('owned','leased','public','collection_site','other'))`.
Non-owned tenures skip boundary/acreage/membership requirements in the UI;
capture and mapping work identically everywhere. `source_plants` may live on any
property regardless of tenure (complements `is_on_property`/`origin_notes`).
This is the only approved deviation from the §4 contract so far. THis is good

### D-005 · Tag codes: free text with auto-suggest (spec §9.2)
Free-text `tag_code`, with the UI suggesting the next code in the user's last-used
pattern (e.g. `SFS-BW-041`). No enforced format, no QR scanner in v1 — schema is
unchanged either way, so scanning can be added later.

### Deferred (decide at Milestone 4)
- §9.3 Naturalist suggestion notifications vs. silent review queue. - Yes
- §9.4 Guest-link default (spec default stands for now: fuzzed, 30-day expiry).

## 2026-08-17 — Build-out decisions (made autonomously, flag if wrong)

### D-006 · Offline basemap distribution: user-supplied URL for v1
The in-app downloader accepts any direct `.pmtiles` URL (resumable). On-device
bbox extraction from build.protomaps.com was considered and deferred — it means
implementing a PMTiles v3 archive *writer* in Dart. Revisit if the URL flow
proves too technical for non-Austin users. Since people may be off grid or away from cell service when they are using the app, the app needs to remember locations and such so that when it reconnects, it updates its data. (download over wifi or cellular option for users who are data use sensitive?)

### D-007 · Photo point anchoring: first visit sets position/bearing/reference
Rather than asking the user to type a bearing, the first captured frame anchors
the point: GPS position, compass bearing, and the reference image are taken
from that visit. Compass is tilt-compensated accelerometer+magnetometer
(sensors_plus), smoothed; no rotation-vector dependency. great. 

### D-008 · Track raw points are discarded after save
Spec §4.13 says retain raw points "only for the active track" — implemented
literally: on stop, the simplified LineString (Douglas-Peucker 5 m) plus total
distance is stored and `track_points` rows for that track are deleted. great

### D-010 · Convenience backup is a first-class option (Austin, 2026-08-17)
Spec §11.6 offered "convenience mode" defaulted off and heavily caveated.
Austin explicitly wants a minimal-security Google Drive backup as a fine
default for people who don't care: same backup structure, no passphrase, no
encryption. The encrypted path remains available and the mode is clearly
labeled at setup. This overrides the spec's "default off, state plainly what
this trades away" framing only in emphasis, not in mechanics — the choice is
still explicit. great. 

### D-011 · Crypto stack: `cryptography` (pure Dart) instead of libsodium
Spec §11.4 named libsodium. The `cryptography` package provides the same
primitives (Argon2id, XChaCha20-Poly1305 AEAD, HMAC-SHA256) as a maintained
library — not hand-rolled — while being host-testable (no native lib to load
in `flutter test`) . Files are encrypted whole-file AEAD rather than
secretstream-chunked: media working copies are ~400 KB and originals a few
MB, so chunking buys nothing yet; revisit for video. Blob names are
HMAC-SHA256(master key, sha256) per spec.

### D-009 · Release keystore location
`~/.keystores/fieldnotes-release.jks`, password in
`~/.keystores/fieldnotes-release.pass` (plaintext on this machine, outside the
repo). `android/key.properties` is gitignored. LOSING THE KEYSTORE MEANS
FUTURE APKS CANNOT UPDATE IN PLACE — back these two files up.

---

## 2026-08-26 — Audit-day decisions (reviewed by Austin 2026-08-26)

### D-012 · Undo hard-deletes a seconds-old observation (accepted 2026-08-26)
Spec §4.1 says soft delete everywhere. The save-toast UNDO instead erases the
observation, its media links, media rows and files, identification
suggestions, and its env-context row outright. Rationale: the record is
seconds old, has never left the phone, and a tombstone would still drag the
photo into the next backup and export. Explicit DELETE on the detail screen
remains a soft delete. Sync (M4) never sees an undone record because it never
existed long enough to upload. Alternative: tombstone the observation *and*
its media rows — keeps §4.1 pure at the cost of orphan photos in backups.

### D-013 · Export leaves the phone as a zip via the share sheet (accepted 2026-08-26)
Spec §6 wanted the export folder written to shared storage for USB/MTP. Since
2026-08-17 the export is zipped and handed to the Android share sheet (Drive,
email, Files, USB via a file manager). Agreed in-session then; logging it now.
The MTP folder can be added later as a second destination without changing
the export contents.

### D-014 · Product name stays **Field Notes** (Austin, 2026-08-26 — "Field notes is fine")
The design handoff had drifted to "Field Station". Rejected: D-001 stands.
Launcher label, first-run screen, track notification, export share text and
any other user-facing string say "Field Notes". Repo/package/bundle id
unchanged.

### D-015 · Region-sourced species library (Austin, 2026-08-26 — new requirement)
Austin: users should pick their region (or the app should use GPS) and the app
builds the species list from a public source such as USDA PLANTS rather than
asking people to upload lists. Users then add species they actually find on
the property, with the identification tool's help; uploading a list stays an
option, not the default. Plan: bundle a compact USDA PLANTS-derived dataset
(state-level distribution: scientific/common name, family, growth form,
nativity) so it works offline; resolve the state from the property centroid
via bundled state polygons; the current Edwards Plateau seed becomes one
regional palette among many. Scheduled after the daily-drive set; before M5
photo ID, which it feeds.

### D-016 · Offline-first network policy (Austin, 2026-08-26, on D-006)
Users are often off-grid. Anything that needs the network is queued and
completed on reconnect (env-context backfill already works this way; species
identification will), and large downloads (basemap capture, backups) default
to Wi-Fi only with a per-user "allow cellular" switch for people who aren't
data-sensitive. Location is never a network dependency.

### §9.3 resolved · Naturalist suggestions notify the Steward (Austin, 2026-08-26)
Notification, not a silent queue. Applies at M4.

### D-017 (proposed) · Features get a maintenance due date — §4 schema addition
Spec §7.9 wants "maintenance due" on features, but §4.3 `features` has no
due/interval columns. Proposal: add `maintenance_interval_days INTEGER` and
`next_due_on TEXT` to `features` (mirroring `photo_points.cadence_days` /
`next_due_on`), set on creation and rolled forward when a condition log with
`action_taken` is saved. Second approved deviation from the §4 contract if
accepted; otherwise "maintenance due" is out of scope for v1. Not implemented
until Austin signs off.

### D-018 · Survival: cohort rate over `count_planted`; tag rate over tagged plants, labelled
Spec §4.8 says survival is derived over `count_planted`. Cohort check-ins do
exactly that ("31 of 40 alive · 78%"). Tagged-individual checks are a sample
— 3 tags on 40 cuttings would read as 8% if divided by `count_planted` — so
the tag-derived figure is shown as "3 of 3 tagged alive · of 40 planted",
never as a percent of the cohort. Both stay derived, never stored.

### D-019 · Backup to a computer on your own LAN (new capability)
Spec §11.5 listed Google Drive, iCloud, S3 and "local folder / USB" as
targets. Adding a fifth: the desktop app runs a receiver, the phone pushes
the same encrypted blob store to it over the local network. Pairing is a
six-digit code shown on the desktop, used as a bearer token. The receiver
never decrypts — the phone encrypts first and the computer holds opaque
files with HMAC names. This is the strongest privacy option the app offers
(no account, no internet, no third party) and it costs nothing to operate.
`BackupTarget` made it a drop-in: the engine is unchanged.

### D-020 · Pl@ntNet keys stay bring-your-own; friction removed instead
Austin asked whether "sign in with Google" on my.plantnet.org could let the
app fetch a user's key on the backend. It can't: that button signs a person
into Pl@ntNet's own website; Pl@ntNet is not an OAuth provider a third
party can use to obtain a key or act on a user's behalf. The alternative —
one key of ours serving every user — needs a commercial contract (their
quotas are per account), a proxy server so the key isn't extractable from
the APK, and would route every photo through us, which contradicts the
app's core promise. Rejected for now; revisit only as a deliberate business
decision. Instead the friction is removed: one tap opens Pl@ntNet (where
Google sign-in works fine), and on return the key is read from the
clipboard, validated against the API, and saved.

### D-021 · Google Drive backup: `drive.appdata` only, and never the default
Spec §11.5 listed Google Drive as a target; it is now built (`DriveTarget`,
`DriveAuth`). Three constraints, all deliberate:

**Scope.** The only scope requested is `drive.appdata` — a hidden folder
Drive creates for this app, invisible to the user's file list and to every
other app. It cannot read what was already in the Drive. This is also why
the app can go to Production without Google's restricted-scope security
assessment: `appdata` is classed non-sensitive, unlike full Drive access.

**Encryption is unchanged.** The Drive target sits under the same engine as
every other, so the phone seals each object before upload. Google stores
ciphertext with HMAC names and holds no key. Signing in creates no account
with us and syncs nothing.

**Framing.** The Backup screen and the walkthrough both say Drive is the
convenient option and LAN (D-019) is the private one. Drive is never
preselected and nothing signs in on launch; `accessToken(interactive:
false)` exists precisely so the automatic runner can reuse a grant without
putting a Google dialog in front of someone standing in a field.

Implementation note: Drive has no paths. `fieldnotes/blobs/ab/cd` is stored
flat as `fieldnotes__blobs__ab__cd`, and the whole app folder is listed once
per target instance into a name→id index — `BackupEngine.backup` calls
`exists()` once per blob, and a query apiece would make a first backup of a
few hundred photos take minutes.

Cloud project `field-notes-506920`; the Web client ID is in `DriveAuth` and
is not a secret. Publishing status is **Testing** until there is a public
home page and privacy policy URL to register — see the note in
`docs/GOOGLE-DRIVE-SETUP.md`.
