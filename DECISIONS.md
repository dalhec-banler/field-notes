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
is not a secret. **Published to production 2026-08-28**, which required a
public home page and privacy policy on an authorized domain — both now live
as unlisted pages on shortsfieldstation.org (`/fieldnotes` and
`/fieldnotes/privacy`: noindex, out of the sitemap, not in the nav). No
verification or security assessment was needed, `appdata` being
non-sensitive, and the seven-day Testing sign-in expiry is gone.

One behaviour bug found only on the device and fixed the same day: opening
the Drive screen called `attemptLightweightAuthentication()` merely to label
the account, and on Android that goes through Credential Manager and shows
the account picker when no grant exists — so a Google sheet appeared before
the user had touched Connect, contradicting this decision's own third
constraint. The screen now labels from local state; Google is contacted only
from `accessToken()`.

### D-022 · Environmental context is opt-in, and coarsened when on
Spec §4.11 auto-attaches weather and soil to every record, and names
Open-Meteo and USDA-NRCS Soil Data Access as the sources. The feature is
right — "why did these die" is usually answered by drought and soil. The
implementation was not.

As built (2026-08-17) it ran automatically from `main()` on every launch and
sent the record's **full-precision coordinate** to both services. That
contradicts hard rule 3 in `CLAUDE.md` — nothing leaves the device without
explicit user action — and it was inconsistent with the app's own better
instinct elsewhere: the LLM identification path already rounds coordinates
to ~1 km before sending. It was found while writing the public privacy page,
not by the audits, because enumerating every egress point is a different
exercise from reviewing a diff.

Two changes, both enforced in `EnvContextService` rather than at the call
sites, so a future caller cannot reintroduce either:

1. **Off unless switched on.** `backfillStale({bool enabled = false})`
   returns without a request when disabled, and the parameter *defaults to
   off* — a caller that forgets it sends nothing. `AppPrefs.envContext`
   defaults to false; the Settings row describes what leaves the phone
   rather than what you gain.
2. **Rounded before egress.** `_coarse()` (2 dp, ~1.1 km) is applied once in
   `backfillStale` before either fetch. The stored row keeps the true
   coordinate — it is the record's own location and stays local. Weather is
   unchanged at that resolution; a soil map unit occasionally resolves to a
   neighbour, which is the price.

Rows are still created locally while the feature is off, so switching it on
later backfills the history without anything having been sent in the interim.

Tests assert the guarantees directly: zero HTTP requests while off, and that
`31.061847` never appears on the wire while `31.06` does.

Austin's call, 2026-08-28, choosing "off by default, coarsen when on" over
leaving it on-but-coarsened or removing it outright.

### D-023 · Two skins: quiet by default, the press as an easter egg
Austin's call (2026-08-31): the Field Station press aesthetic matches the
Shorts Resort identity but is a strong flavour; the app should default to a
clean contemporary skin, with the press discoverable rather than imposed.

**Architecture.** The app had a constants layer, not a theme layer — 331
`Press.*` refs, 1,117 `Type.*` refs, 120 hand-built TextStyles, and only 10
`Theme.of(context)` lookups. Rather than rename 1,400+ call sites, `Press`
and `Type` kept their names and became getters delegating to a process-wide
`Skin` object (lib/theme/skin.dart): `pressSkin` (values unchanged) and
`quietSkin`. The cost is that token references can no longer be `const`;
an analyzer-driven sweep removed ~700 consts. The active skin is chosen from
prefs before runApp and swapped only via a root-level rebuild
(`ValueKey('skin-…')` on MaterialApp), never mid-frame.

**Pixel-identity contract.** A golden test renders a composite of the press
widgets; its baseline was generated from unmodified main in a git worktree,
and the post-seam branch renders byte-identical against it. The quiet
composite is a second golden as a reviewed reference, not a contract.

**What a skin may vary:** palette, faces (quiet = system), radii, shadows
(hard offset vs soft elevation), border colour/weight (`Press.borderInk`:
ink vs hairline edge), label casing, ornament. **What it may not:** field
ergonomics — touch targets, FAB/shutter sizes, outdoor-mode scaling are
shared in `Metrics`. A skin is a look, not a downgrade for gloved hands.

**The easter egg.** Settings gained an About/Version row (was missing
anyway). Seven taps — the Android developer-options idiom — unlocks the
press: a snackbar speaks in the press's own ink and mono regardless of the
active skin, the skin flips, and a normal Appearance row appears and stays.
`prefs.pressUnlocked` persists the discovery.

Phase 2 (later): quiet is currently the same layouts reskinned — uppercase
literals persist in button copy, and the press furniture (Diamond markers)
renders recoloured rather than redesigned. A designer will clock it as the
same app in different clothes; that's the accepted trade for shipping the
seam first.

### D-024 · The desk edits, refines, and exports; the field device originates
Austin's call (2026-09-01): "the phone is the place of truth, and the
desktop app only ever gets data from the phone or field device" — refined
the same hour to: the desk "should be able to review decisions, make edits,
etc. Sometimes it's easier to refine field notes on the desktop than on the
phone," and its "primary functions should really be editing, refining, and
publishing" — meaning **exporting useful information for publishing**
(maps and reports as PDF/HTML/images for grantors, land-management
partners, the website), not a publish integration.

**What this fixes.** The desktop build inherited the phone's first run —
the "phone in the creek" walkthrough and ADD A PLACE — and creating a
place there red-screened (`_dependents.isEmpty`: the first-run subtree was
swapped for the desk shell under an open dialog). Worse than the crash, it
let a computer invent a property from nothing, which contradicts the desk's
own principle cell ("This desk reads a restored copy; it invents nothing").

**The rule.** Records are *born* on the field device: capture, GPS, camera,
tracks, photo points — none of that exists on the desk. A computer with no
data shows an intake screen (`DesktopIntakeScreen`) with exactly three
ways in — receive from the phone over the LAN, restore from Google Drive,
open a backup file — then quits and reopens on the copy (macOS relaunches
itself; the staged restore applies before the DB opens, spec §11.9). No
ADD A PLACE, no onboarding wizard on desktop.

Once it has the record, the desk is a full editing peer: record edits,
review decisions (the steward's queue from the pending-visible model),
species refinement, programs/costs, and exports. Desk edits reach the
phone through the same oplog as any other device (docs/SYNC-DESIGN.md is
already bidirectional; phone + desk is its first device pair). Until M4a
lands, a desk edit is local to the desk — the intake screen and the shell
say so rather than pretend.

**Exports for publishing** are a desk-first feature: property/zone map
plates (PNG, PDF), an interactive HTML map for the website, and the
existing evidence packet / survival PDF. Constraint discovered the same
day: `maplibre_gl` has no macOS/Linux/Windows platform, so the desk has no
interactive map and cannot render one for export through the plugin. The
map plate is therefore our own renderer — imagery tiles composited with
the property's GeoJSON on a Canvas — which doubles as the desk's on-screen
map. Every export that carries coordinates says so at the point of export
(hard rule 3: nothing leaves without explicit action).

### D-025 · Pairing is a relationship; backup is a destination
Austin's call (2026-09-01), landed piecewise through the day and recorded
here as one decision.

**Pairing** links a phone and a computer as two devices of one record —
one-time, by QR. What it means today: the desk receives the record (LAN
push, Drive restore, or a backup file) and reopens on the copy; the
identification keys ride along inside the sealed body of an encrypted
backup, so one passphrase gives every paired device the same Pl@ntNet and
AI account; the desk watches the shared Drive folder and offers BRING IT
OVER when the phone's generation is newer. Until M4 sync, the desk is a
ONE-WAY MIRROR: it never writes to Drive (a desk backup overwrote the
phone's lineage once — 2026-09-01, generation 4 — and that class of
accident is now structurally impossible), and desk edits stay on the desk.

**Backup to a computer** stays what it was: a destination, not a
relationship. Any computer on the network can receive encrypted files it
cannot open; no pairing, no keys, nothing readable.

**Automatic backups**: the phone (the field device — the only writer)
backs up daily to its local store and, when connected and on Wi-Fi, to
Drive. The desk auto-backs-up locally only.

Deferred to M4b: the desk writing to the shared folder (as oplog, not
backup generations), a Devices section in Settings distinct from Backup,
and key handoff at pairing time over the LAN channel.

### D-026 · Sync exchange stays blocked until the merge model is sound

2026-09-04. An external audit of commit `081be17` found fourteen issues;
`docs/EXTERNAL-AUDIT-2026-09-04.md` is the report and
`app/tool/external_audit_test.dart` its reproductions. Nine were live
defects and are fixed. Five concern the oplog, which captures writes but
is wired to no carrier — `push` and `pull` have no production caller.

Those five are not bugs to file and forget; they are the reasons exchange
does not turn on yet:

1. **Identity travelled inside the journal.** A restored database carried
   the phone's device id, so a desk restored from it wrote the same batch
   names and skipped the phone's work as its own. **Fixed:** the device id
   lives in a file beside the database, never in a backup; a journal that
   arrives from elsewhere earns a new identity and its inherited cursors
   are cleared.
2. **Sync batches are plaintext.** Encryption lives in `BackupEngine`,
   which the oplog never calls; any shared carrier would receive readable
   coordinates and notes and could forge input. **Guarded, not fixed:**
   `push`/`pull` now require an explicit `allowPlaintext: true`, so no
   future wiring can hand these bytes to a carrier by accident. Sealing
   and authenticating batches with the keyring is a precondition of
   activation.
3. **Tombstones are forgotten.** Applying a delete removes the row and its
   version with it, so a peer that was offline during the deletion
   resurrects the row with a stale edit. D-012's brief local undo does not
   license discarding a deletion already exchanged with peers.
4. **The equal-timestamp tiebreak compares the wrong device.** It uses the
   receiving device's id rather than the id of the writer whose value is
   currently stored, so three peers can settle on different rows and stay
   that way.
5. **The clock is the version.** A corrected clock loses a later edit, and
   ISO strings of differing precision compare wrongly as text.

3, 4 and 5 are one piece of work, not three patches: a persisted logical
version per row — monotonic, canonical in representation, carrying the
winning writer's id, and retained for deletions independently of whether
the row still exists. That replaces raw `updated_at` comparison as the
merge rule in SYNC-DESIGN.md.

Until that lands and batches are sealed, sync stays off. The audit's S2,
S3, S4, S4b and S5 reproductions are kept failing on purpose: they are the
specification of done, and they should pass before any carrier is
connected.

**Outcome (same day).** All five blockers are closed. Identity moved out
of the journal; versions are stamped at capture by a hybrid logical clock
in the capture trigger itself, so an edit made offline on Tuesday still
sorts before a deletion made on Wednesday; `sync_versions` keeps the
winning version of every row including tombstones; ties compare the
stored writer, with a deletion beating a write; and batches are sealed
with the backup keyring, carry their device and format, and are refused
if they sit in a directory they do not claim. The audit's S1–S4b
reproductions pass. S5 is left failing because adapting it to the new
signature made it ask for a deliberately-plaintext push to be
unreadable; `test/oplog_sealed_test.dart` asserts the property it was
after — sealed batches are opaque, round-trip, reject the wrong key,
reject a forged sender, and the clear requires saying so.

Sync is still not wired to a carrier. What remains before activation is
product work, not correctness: where the shared folder lives, how the
two devices agree on a key, and what the user sees while it runs.

### D-027 · Removal is management work, recorded on the record

2026-09-07. Austin: "I want to be able to flag things for removal, as
removal is just as an important part of restoration work as planting
things" — ashe juniper, mesquite, chinaberry. Spec §4 gives an
observation no management state. This adds two columns to
`observations` (schema v7): `removal_status` ('flagged' | 'removed') and
`removed_on`.

A flag on the record, not a separate work-order table: the thing being
removed IS the record — its photo, its species, its pin. One column, one
read, and every surface says the same thing: the ledger row, the record
screen, the desk queue, the phone map, the desk map and the printed
plate all draw the same ring-and-cut over the same mark. Clearing the
flag or marking it removed is one write on one row, and a removed record
keeps its history — an ink ring with a tick, and the day it came out.

Downstream: the ledger has a "Removal" chip that the map follows
(D-024's one filter), and the desk's Export bench has a second document,
the removal plan — the plate drawn with ONLY flagged records as numbered
oxblood pins, then the numbered list with each record's photo, species,
nativity, coordinates and notes, for a contractor's hand
(`lib/export/removal_plan.dart`).

### D-028 · Sync is on: the Drive app folder is the carrier

2026-09-07. Austin: "the UX is fucked as it stands currently" — the desk
could edit and could not send. D-026 had closed every correctness
blocker and left three product choices. They are made:

1. **Where the shared folder lives.** The hidden Drive app folder the
   backup already writes (D-021). No new scope, no folder to pick, no
   second place to explain. Each device writes only under
   `sync/<device_id>/`; nobody writes a file anyone else writes.
   (Sharing with other people — SYNC-DESIGN's `drive.file` folder — is
   still ahead; this is one human's phone and desk.)
2. **How the devices agree on a key.** The backup keyring. The desk
   already holds the data key from the day it restored the phone's copy;
   the phone caches it for the daily backup. Sync batches and media are
   sealed with it and nothing else; a device without it is told to open
   Sync and enter the passphrase once.
3. **What the person sees.** One screen, *Sync with Drive*, on both
   devices: account, last synced, what's waiting, SYNC NOW, and the
   automatic switch. The desk's banner stops announcing "a newer copy in
   Drive" once it has synced and instead says how many of its edits the
   phone hasn't got. Automatic runs on open, on resume, and (desk) every
   few minutes — at most once per fifteen — and never prompts.

Two rules the carrier needed that the log did not have:

- **A journal that arrived by restore belongs to its writer.** The desk
  was born from the phone's database, sync tables included; pushing that
  journal would re-author the phone's history as the desk's. A device
  that has never pushed keeps only ops for rows it wrote (sync_versions
  says who), and starts its cursor for the writer at what the copy
  already holds. Keyed on "never pushed", so a desk adopted before this
  rule heals itself on its next launch.
- **A path is not a fact about the record.** `media.local_path`,
  `thumb_path`, `remote_path` and `upload_state` are captured but never
  applied. The receiving device fetches the blob from the same
  `blobs/` the backup fills and files it under its own layout, quietly.

Media travel by the backup's blob store, content-addressed and already
deduplicated; photos wait for Wi-Fi unless cellular is allowed (D-016).
`test/sync_service_test.dart` is the acceptance: a record and its photo
cross as a row and a file, an edit comes back, a deletion travels, paths
never cross, a 1,200-op history goes up in bounded batches, and an
adopted desk pushes only its own work.

### D-029 · A batch lives where the bench is; the story reads from either end

2026-09-08. Austin found that Grow follows the map you stand on ("that
also totally makes sense, so we should leave it that way"), then asked
where a batch should live when the bench is at home, the material came
from a lake, a road, or a seed order, and nine in ten plants are bound
for Shorts. Four readings were laid out — the bench, the destination,
the origin, no place at all — and the bench won: it is honest about
where the trays are, keeps one bench one list, and survives a second
bench someday.

What changed so the other ends can be seen:

1. **Propagation reads from wherever you stand.** Three groups instead
   of one: *on the bench here*, *collected from here*, *planted out
   here* — the last two only for batches whose bench is elsewhere, so
   nothing lists twice. Standing on Shorts you see what is coming; on a
   collection site, what left it and where it went.
2. **A mother plant is filed where it grows.** The batch form asks the
   material (seed, cutting, sucker…) and where from: one of the places,
   or ordered with a vendor. On a place, the mother plant can be linked
   to the record it was found as — `source_plants.observation_id`, an
   approved §4 deviation — and that link is the map button: it opens
   that place's map on that pin, on the phone and the desk.
3. **A planting can come from anywhere.** Own propagation picks a batch
   from any bench and the batch logs the count that left (status
   planted out once the bench is empty); nursery stock names the
   nursery (`vendor`) and lot; volunteers and transplants stay as they
   were. Plant out from a batch asks the place, defaulting to where the
   batch last went.
4. **"Other" gets a blank.** `propagation_batches.method_other`, the
   second §4 deviation. And *Medium* reads *Soil mix*.

Schema v8 adds the two columns; sync carries them like any other.
`test/lineage_test.dart` is the acceptance: a batch on one bench with
material from a second place and a planting on a third appears in all
three lists, and a planting from a batch takes its count off the bench.
