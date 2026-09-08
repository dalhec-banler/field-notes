# Field Station — Build Specification v0.1

**Author:** Product / Austin
**Status:** Handoff draft — ready for implementation
**Target:** Android sideload (APK) first, desktop second, iOS third

---

## 0. How to read this document

This is a build spec, not a wish list. Section 4 (data model) is the contract — everything else can be renegotiated, but the schema should be implemented as written because the whole product's extensibility depends on it.

Where I've made a decision that has a plausible alternative, I say so in a **Decision** block with the rejected option and why. Don't silently re-litigate these; if you disagree, flag it before building.

Where something is genuinely uncertain and needs verification during implementation, it's marked **⚠ VERIFY**.

---

## 1. What this is

A local-first field journal for people who own and actively manage land.

The user walks their property, photographs plants, and records what they see. Every record is a point on a map with a timestamp, a photo, an optional species, and notes. Plantings are tracked from cutting collection through propagation through planting through survival, over years. Infrastructure and problem areas — springs, guzzlers, erosion zones, wetlands — are mapped and their condition tracked over time.

The data lives on the phone. It works with the radio off. Sharing is opt-in, per-property, and role-gated.

### Core principles (do not violate these)

1. **Offline is the default state, not a degraded mode.** Every read and write hits local SQLite. Network is an enhancement.
2. **The user's data is theirs and portable.** A full export must reconstruct the entire dataset in open formats with no vendor dependency.
3. **Precise coordinates of private land are sensitive.** Nothing leaves the device without an explicit user action. No analytics on record content, no telemetry containing coordinates.
4. **Continuity over volume.** The valuable record is the same plant photographed eight times over four years, not 8,000 one-off observations. Design every flow to make the *return visit* effortless.

### Non-goals for v1

- Parcel/ownership data (that's OnX and Land.id's business, and it's expensive licensing)
- Carbon quantification or funder-facing MRV reporting
- A public social feed
- Real-time collaboration / live cursors
- iOS

---

## 2. Users and roles

The owner invites family and collaborators to a property. Roles gate write access.

| Role | Intent | Read | Create observations | Edit others' records | Manage plantings/propagation | Manage zones & features | Invite others | Delete property / billing |
|---|---|---|---|---|---|---|---|---|
| **Steward** | Owner | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ |
| **Ranger** | Trusted manager, spouse, land manager | ✅ | ✅ | ✅ | ✅ | ✅ | ✅ | ❌ |
| **Scout** | Family, helper, contractor | ✅ | ✅ | own only | check-ins only | ❌ | ❌ | ❌ |
| **Naturalist** | Visiting botanist, extension agent | ✅ | ✅ (flagged `is_suggestion`) | ❌ | ❌ | ❌ | ❌ | ❌ |
| **Guest** | Mom, brother, curious friend | ✅ | ❌ | ❌ | ❌ | ❌ | ❌ | ❌ |

Notes:
- A property always has exactly one Steward. Transfer is an explicit action.
- **Naturalist** exists specifically so an expert can suggest IDs and add observations without being able to alter the owner's records. Their observations appear with a distinct marker until a Ranger or Steward accepts them.
- Every role is scoped to a single property. A user with three properties has three membership rows.
- Permission checks must be enforced **both** client-side (UI affordance) and server-side (RLS). Client-side alone is not a permission system.

### Guest link sharing

Stewards can generate a read-only share link without requiring the recipient to create an account. Link options:

- `precise` — true coordinates
- `fuzzed` — coordinates jittered within a configurable radius (default 500 m), for sharing publicly
- `zone_only` — records shown grouped by zone with no coordinates at all

Links carry an optional expiry and can be revoked. Default is `fuzzed` with 30-day expiry — the safe default, deliberately.

---

## 3. Technology decisions

### 3.1 Framework

**Decision: Flutter (Dart).**

Rationale: the four load-bearing capabilities are camera, GPS, EXIF, and offline vector maps. Flutter has mature, maintained plugins for all four, real desktop targets, and `flutter build apk` produces a sideloadable artifact in one command.

*Rejected:* Tauri v2 — excellent desktop story and the best PMTiles path (MapLibre GL JS in a webview), but its mobile camera/geolocation plugins are younger, and this app lives or dies on those. *Rejected:* Kotlin Multiplatform — best Android experience, weakest desktop/iOS map story.

### 3.2 Local database

**Decision: SQLite via the PowerSync Flutter SDK, with `drift` for typed queries.**

PowerSync embeds its own SQLite and keeps it in sync with a Postgres backend, with an upload queue that drains when connectivity returns. This is the exact shape of our problem: local reads/writes always, sync as an enhancement, per-user data scoping via sync rules.

Critically, PowerSync is the only one of the mainstream sync engines with first-class *offline* support — ElectricSQL deliberately doesn't handle client-side persistence, and Zero has stated offline is out of scope. Don't substitute either.

**Sync must be optional.** A user who never signs in gets a fully functional app backed by the same local SQLite. Sync switches on when they create an account. Build and test the no-account path first.

### 3.3 Backend

**Decision: Supabase (Postgres + Auth + Storage) behind PowerSync.**

- Auth: Supabase Auth (email magic link; no password to lose in the field)
- Row Level Security enforces the role matrix in §2
- Storage: media blobs, uploaded lazily and only on Wi-Fi by default
- PowerSync Sync Rules define which property buckets sync to which user

⚠ VERIFY: PowerSync docs flag a known Supabase logical-replication WAL growth issue on idle instances. Check current status before provisioning and set `archive_timeout` appropriately.

### 3.4 Maps

**Decision: `maplibre_gl` (the official MapLibre Flutter plugin) with PMTiles basemaps.**

PMTiles is a single-file tile archive read via HTTP range requests — no tile server, no vendor key. MapLibre Native gained PMTiles support in Android 11.9.0 / iOS 6.14.0 and handles the `pmtiles://` protocol internally.

**⚠ CRITICAL IMPLEMENTATION CONSTRAINT:** MapLibre Native's PMTiles sources **do not support offline pack downloads or caching**, and MapLibre Native requires the URL inside `pmtiles://` to be fully specified (`pmtiles://https://host/tiles.pmtiles`, not a relative path). This means you cannot simply bundle a `.pmtiles` asset and reference it by relative path.

**Required approach:** download the `.pmtiles` archive to the app documents directory, then run a minimal local HTTP server (`shelf` + `shelf_static`, bound to `127.0.0.1` on an ephemeral port) that correctly serves HTTP `Range` requests, and point the style at `pmtiles://http://127.0.0.1:<port>/basemap.pmtiles`. Range support is mandatory — PMTiles is unusable without it.

Fallback if the local-server approach proves unstable: MBTiles (SQLite-backed) read directly, which has an established Flutter+MapLibre pattern. Prototype the PMTiles path in the first two days; if it fights you, switch early rather than late.

**Tile budget sanity check:** a 103-acre property is ~0.42 km². At z19 that's roughly 100 tiles, ~130 including all lower zooms — call it 4 MB of satellite imagery. An entire Texas county at z16 with z19 only over the parcel stays comfortably under 1 GB. Storage is not the constraint here; don't over-engineer tile management.

### 3.5 Other packages

| Need | Package | Notes |
|---|---|---|
| Location | `geolocator` | Request `whileInUse`; upgrade to `always` only when track logging is enabled |
| Camera | `camera` | Needed for the photo-point ghost overlay; `image_picker` is insufficient |
| EXIF read/write | `native_exif` | Must write GPS into exported JPEGs |
| Image resize | `image` | Downscale to 1600 px long edge for the working copy |
| Voice transcription | `speech_to_text` | Uses platform ASR; offline on Android with a downloaded language pack. Store transcript **and** the audio file — never discard the audio |
| Audio capture | `record` | |
| Geometry ops | `turf_dart` | Point-in-polygon for zone auto-assignment, area/length calc |
| KML/KMZ | `xml` + `archive` | KMZ is a zipped KML |
| Local HTTP server | `shelf`, `shelf_static` | For PMTiles; must support Range |
| Archive export | `archive` | |

---

## 4. Data model

SQLite DDL below. The Postgres schema mirrors it with `uuid`, `timestamptz`, `jsonb`, and RLS policies added.

### 4.1 Conventions — apply to every table

- **Primary keys are UUIDv7 TEXT.** Time-ordered, generated client-side, no coordination needed for offline creation. Never use autoincrement integers — they collide across devices.
- Every user-data table carries: `property_id`, `created_by`, `created_at`, `updated_at`, `deleted_at` (soft delete; sync engines need tombstones).
- Timestamps are **ISO-8601 UTC strings** with a separate `local_tz` where the wall-clock matters (field records are meaningless without knowing it was 6 AM local).
- Geometry is stored as **GeoJSON in a TEXT column**, plus denormalized `lat`/`lng` REAL columns on point-bearing tables for fast bbox queries and indexing. Do not attempt SpatiaLite on mobile — the build pain is not worth it at this data volume.
- Enum-like fields are TEXT with a CHECK constraint, not integers. Readable exports matter more than four bytes.

### 4.2 Identity and access

```sql
CREATE TABLE profiles (
  id            TEXT PRIMARY KEY,
  display_name  TEXT NOT NULL,
  email         TEXT,
  avatar_media_id TEXT,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL
);

CREATE TABLE properties (
  id            TEXT PRIMARY KEY,
  name          TEXT NOT NULL,
  description   TEXT,
  county        TEXT,
  state         TEXT,
  country       TEXT DEFAULT 'US',
  acreage       REAL,
  boundary_geojson TEXT,             -- Polygon/MultiPolygon
  centroid_lat  REAL,
  centroid_lng  REAL,
  default_share_mode TEXT NOT NULL DEFAULT 'fuzzed'
                CHECK (default_share_mode IN ('precise','fuzzed','zone_only')),
  fuzz_radius_m INTEGER DEFAULT 500,
  created_by    TEXT NOT NULL,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  deleted_at    TEXT
);

CREATE TABLE memberships (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL REFERENCES properties(id),
  profile_id    TEXT NOT NULL REFERENCES profiles(id),
  role          TEXT NOT NULL
                CHECK (role IN ('steward','ranger','scout','naturalist','guest')),
  invited_by    TEXT,
  accepted_at   TEXT,
  created_at    TEXT NOT NULL,
  updated_at    TEXT NOT NULL,
  deleted_at    TEXT,
  UNIQUE (property_id, profile_id)
);

CREATE TABLE invites (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL REFERENCES properties(id),
  token         TEXT NOT NULL UNIQUE,
  role          TEXT NOT NULL,
  email         TEXT,                -- null = open link
  share_mode    TEXT,                -- for guest links
  expires_at    TEXT,
  max_uses      INTEGER,
  use_count     INTEGER NOT NULL DEFAULT 0,
  revoked_at    TEXT,
  created_by    TEXT NOT NULL,
  created_at    TEXT NOT NULL
);
```

### 4.3 Spatial framework

**Zones** are named subdivisions of the property — Austin's seven restoration sections, a riparian corridor, a pasture. They are hierarchical and are the primary filter dimension across the whole app.

**Features** are everything else mappable and persistent: a spring, a wetland, a headcut, a guzzler, a gate, an exclosure fence, a road. These split naturally into two classes but share one table because the boundary is genuinely fuzzy — a spring is a point source with a seasonal wetted extent, and forcing it into "point" or "polygon" loses information.

```sql
CREATE TABLE zones (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL REFERENCES properties(id),
  parent_zone_id TEXT REFERENCES zones(id),
  name          TEXT NOT NULL,
  code          TEXT,                -- e.g. 'SFS-S3'
  zone_type     TEXT CHECK (zone_type IN
                 ('riparian','upland','xeric','wetland','woodland','grassland',
                  'pasture','wet_depression','developed','other')),
  geojson       TEXT NOT NULL,       -- Polygon
  area_acres    REAL,
  color_hex     TEXT,
  notes         TEXT,
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);

-- User-extensible registry. Seed with defaults; users add their own.
CREATE TABLE feature_types (
  id            TEXT PRIMARY KEY,
  property_id   TEXT,                -- NULL = global seed type
  key           TEXT NOT NULL,       -- 'spring','guzzler','erosion_zone'...
  label         TEXT NOT NULL,
  feature_class TEXT NOT NULL
                CHECK (feature_class IN ('natural','infrastructure','problem')),
  icon          TEXT,
  default_geometry TEXT
                CHECK (default_geometry IN ('point','line','polygon')),
  tracks_condition INTEGER NOT NULL DEFAULT 1,
  created_at    TEXT NOT NULL
);

CREATE TABLE features (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL REFERENCES properties(id),
  zone_id       TEXT REFERENCES zones(id),
  feature_type_id TEXT NOT NULL REFERENCES feature_types(id),
  name          TEXT,
  geojson       TEXT NOT NULL,       -- Point, LineString, or Polygon
  lat           REAL, lng REAL,      -- centroid, denormalized
  installed_on  TEXT,                -- for infrastructure
  retired_on    TEXT,
  current_condition TEXT CHECK (current_condition IN
                 ('good','fair','poor','critical','unknown')),
  attributes_json TEXT,              -- type-specific: flow_rate_gpm, capacity_gal...
  notes         TEXT,
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);

CREATE TABLE feature_condition_logs (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  feature_id    TEXT NOT NULL REFERENCES features(id),
  observed_at   TEXT NOT NULL,
  condition     TEXT NOT NULL,
  measurements_json TEXT,            -- flow, depth, headcut advance in cm...
  action_taken  TEXT,
  notes         TEXT,
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);
```

**Seed `feature_types` with:** spring, seep, stock tank, wetland, wet depression, drainage, erosion zone / headcut, gully, water guzzler, trough, well, gate, fence line, exclosure, cage, road, trail, culvert, crossing, brush pile, snag, den site, burn unit, food plot, structure.

### 4.4 Species library

```sql
CREATE TABLE taxa (
  id            TEXT PRIMARY KEY,
  property_id   TEXT,                -- NULL = global/shared taxon
  scientific_name TEXT NOT NULL,
  common_name   TEXT,
  family        TEXT,
  rank          TEXT DEFAULT 'species',
  growth_form   TEXT CHECK (growth_form IN
                 ('tree','shrub','forb','graminoid','vine','succulent',
                  'fern','moss','other')),
  nativity      TEXT CHECK (nativity IN
                 ('native','introduced','invasive','cultivated','unknown')),
  -- external identifiers, all nullable
  gbif_key      TEXT,
  inat_taxon_id TEXT,
  usda_plants_symbol TEXT,
  itis_tsn      TEXT,
  notes         TEXT,
  is_favorite   INTEGER NOT NULL DEFAULT 0,   -- surfaces in quick-pick
  created_by TEXT, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);
CREATE INDEX idx_taxa_sci ON taxa(scientific_name);
CREATE INDEX idx_taxa_common ON taxa(common_name);
```

**Seed requirement:** ship a starter library for the target region. For SFS that's the ~41-species working palette plus common Limestone Cut Plain (Cross Timbers) / Lampasas Cut Plain natives and the usual invasive suspects (KR bluestem, Johnsongrass, ligustrum, chinaberry, Chinese tallow, Malta star-thistle). Species search must be typo-tolerant and match on common name, scientific name, and family.

### 4.5 Observations — the general record

```sql
CREATE TABLE observations (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL REFERENCES properties(id),
  zone_id       TEXT REFERENCES zones(id),      -- auto-assigned by point-in-polygon
  feature_id    TEXT REFERENCES features(id),   -- optional: observed at/about a feature
  observed_at   TEXT NOT NULL,
  local_tz      TEXT NOT NULL,
  lat           REAL NOT NULL,
  lng           REAL NOT NULL,
  gps_accuracy_m REAL,
  altitude_m    REAL,
  heading_deg   REAL,
  observation_type TEXT NOT NULL DEFAULT 'general' CHECK (observation_type IN
                 ('general','plant','wildlife','problem','water','soil',
                  'phenology','sign','weather','maintenance')),
  taxon_id      TEXT REFERENCES taxa(id),
  taxon_confidence TEXT CHECK (taxon_confidence IN
                 ('certain','probable','uncertain','unidentified')),
  count_estimate INTEGER,
  phenology     TEXT CHECK (phenology IN
                 ('vegetative','budding','flowering','fruiting','seeding',
                  'senescent','dormant','dead')),
  is_suggestion INTEGER NOT NULL DEFAULT 0,   -- naturalist-role submissions
  accepted_at   TEXT,
  accepted_by   TEXT,
  notes         TEXT,
  env_context_id TEXT REFERENCES env_contexts(id),
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);
CREATE INDEX idx_obs_prop_time ON observations(property_id, observed_at DESC);
CREATE INDEX idx_obs_bbox ON observations(property_id, lat, lng);
CREATE INDEX idx_obs_taxon ON observations(taxon_id);
```

### 4.6 Identification provenance

Never overwrite a machine ID onto a record without keeping the trail. Every suggestion, from every source, is retained.

```sql
CREATE TABLE identification_suggestions (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  observation_id TEXT NOT NULL REFERENCES observations(id),
  source        TEXT NOT NULL CHECK (source IN
                 ('plantnet','on_device','llm_rerank','human','manual')),
  source_detail TEXT,                -- model name/version, flora/project used
  suggested_taxon_id TEXT REFERENCES taxa(id),
  suggested_name TEXT NOT NULL,      -- raw string as returned
  score         REAL,                -- 0..1
  rank_position INTEGER,
  reasoning     TEXT,                -- LLM re-rank rationale, shown to user
  raw_response_json TEXT,
  accepted      INTEGER NOT NULL DEFAULT 0,
  created_by TEXT, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);
```

### 4.7 Propagation lineage

This is the differentiating feature. Nothing else on the market tracks provenance from mother plant to planted individual.

```sql
CREATE TABLE source_plants (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  taxon_id      TEXT REFERENCES taxa(id),
  label         TEXT NOT NULL,       -- 'Riverbank willow #3'
  lat REAL, lng REAL,
  zone_id       TEXT REFERENCES zones(id),
  is_on_property INTEGER NOT NULL DEFAULT 1,
  origin_notes  TEXT,                -- 'Terlingua, 2019' — offsite provenance
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);

CREATE TABLE collection_events (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  source_plant_id TEXT REFERENCES source_plants(id),
  collected_on  TEXT NOT NULL,
  material_type TEXT NOT NULL CHECK (material_type IN
                 ('hardwood_cutting','softwood_cutting','semi_hardwood_cutting',
                  'seed','sucker','division','layer','transplant','scion')),
  quantity      INTEGER,
  collector     TEXT,
  lat REAL, lng REAL,
  notes         TEXT,
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);

CREATE TABLE propagation_batches (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  collection_event_id TEXT REFERENCES collection_events(id),
  taxon_id      TEXT REFERENCES taxa(id),
  batch_code    TEXT,                -- user-facing label, e.g. 'M-07'
  started_on    TEXT NOT NULL,
  method        TEXT CHECK (method IN
                 ('water_rooting','perlite_coir','direct_stick','flood_tray',
                  'cold_moist_strat','warm_strat','scarification','direct_sow','other')),
  container     TEXT,                -- 'Stuewe D40 deepot'
  medium        TEXT,
  location      TEXT,                -- 'indoor bench, ebb-and-flow'
  count_started INTEGER,
  count_current INTEGER,
  status        TEXT CHECK (status IN
                 ('active','rooted','hardening','planted_out','failed','archived')),
  notes         TEXT,
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);

CREATE TABLE batch_events (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  batch_id      TEXT NOT NULL REFERENCES propagation_batches(id),
  occurred_at   TEXT NOT NULL,
  event_type    TEXT NOT NULL CHECK (event_type IN
                 ('check','water','fertilize','pot_up','treat','mortality',
                  'root_check','move','harden_off','note')),
  count_delta   INTEGER,             -- negative for mortality
  count_after   INTEGER,
  measurements_json TEXT,
  notes         TEXT,
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);
```

### 4.8 Plantings and survival

The parent/child split is deliberate and load-bearing. Phone GPS is 3–5 m at best, so 40 caged cuttings on a riverbank will not resolve into 40 distinct pins. Identity comes from a **physical tag** (numbered aluminum tag or flagging on the cage); the coordinate only gets you to the right corner of the field.

```sql
CREATE TABLE planting_events (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  zone_id       TEXT REFERENCES zones(id),
  taxon_id      TEXT REFERENCES taxa(id),
  planted_on    TEXT NOT NULL,
  stock_source  TEXT NOT NULL CHECK (stock_source IN
                 ('own_propagation','purchased_container','purchased_bareroot',
                  'direct_seed','volunteer','transplant_onsite')),
  batch_id      TEXT REFERENCES propagation_batches(id),   -- lineage link
  vendor        TEXT,
  lot_code      TEXT,
  count_planted INTEGER NOT NULL,
  spacing_m     REAL,
  protection    TEXT CHECK (protection IN
                 ('none','welded_wire_cage','tree_tube','fencing','mulch_only','other')),
  geojson       TEXT,                -- Point or Polygon for the planting area
  lat REAL, lng REAL,
  planting_notes TEXT,
  env_context_id TEXT REFERENCES env_contexts(id),
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);

CREATE TABLE plants (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  planting_event_id TEXT NOT NULL REFERENCES planting_events(id),
  tag_code      TEXT,                -- physical tag; the real identity
  lat REAL, lng REAL,
  gps_accuracy_m REAL,
  current_status TEXT NOT NULL DEFAULT 'alive' CHECK (current_status IN
                 ('alive','dead','missing','dormant','browsed','declining','removed')),
  last_checked_at TEXT,
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT,
  UNIQUE (property_id, tag_code)
);

CREATE TABLE plant_checkins (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  plant_id      TEXT REFERENCES plants(id),
  planting_event_id TEXT REFERENCES planting_events(id),  -- cohort-level check
  checked_at    TEXT NOT NULL,
  status        TEXT NOT NULL,
  count_alive   INTEGER,             -- for cohort-level checks
  count_dead    INTEGER,
  height_cm     REAL,
  dbh_cm        REAL,
  canopy_width_cm REAL,
  vigor         TEXT CHECK (vigor IN ('excellent','good','fair','poor','dead')),
  browse_pressure TEXT CHECK (browse_pressure IN ('none','light','moderate','severe')),
  phenology     TEXT,
  protection_intact INTEGER,
  notes         TEXT,
  env_context_id TEXT REFERENCES env_contexts(id),
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT,
  CHECK (plant_id IS NOT NULL OR planting_event_id IS NOT NULL)
);
```

**Survival rate** is derived, never stored: for a planting event, count distinct `plants` with latest status `alive` over `count_planted`, or use the most recent cohort-level check-in. Never denormalize this — it will drift.

### 4.9 Photo points

```sql
CREATE TABLE photo_points (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  zone_id       TEXT REFERENCES zones(id),
  name          TEXT NOT NULL,
  lat REAL NOT NULL, lng REAL NOT NULL,
  bearing_deg   REAL NOT NULL,
  camera_height_cm REAL,
  subject       TEXT,                -- 'looking downstream at willow planting'
  cadence_days  INTEGER,             -- reminder interval
  next_due_on   TEXT,
  reference_media_id TEXT,           -- the anchor frame for ghost overlay
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);

CREATE TABLE photo_point_visits (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  photo_point_id TEXT NOT NULL REFERENCES photo_points(id),
  visited_at    TEXT NOT NULL,
  actual_lat REAL, actual_lng REAL,
  actual_bearing_deg REAL,
  alignment_score REAL,              -- optional, if we compute frame similarity
  notes         TEXT,
  env_context_id TEXT REFERENCES env_contexts(id),
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);
```

**Ghost overlay (required):** when capturing at an established photo point, render the reference frame at ~35% opacity over the live camera preview, with a compass readout showing degrees off the recorded bearing and a distance readout from the recorded position. Green when within 3 m and 5°. This one feature is what makes a multi-year series actually align, and it's cheap to build.

### 4.10 Media

Unified table covering photos, audio (voice notes and bioacoustic clips), and video.

```sql
CREATE TABLE media (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  media_type    TEXT NOT NULL CHECK (media_type IN ('photo','audio','video')),
  local_path    TEXT,
  remote_path   TEXT,
  thumb_path    TEXT,
  sha256        TEXT,                -- dedupe
  bytes         INTEGER,
  width INTEGER, height INTEGER,
  duration_ms   INTEGER,
  captured_at   TEXT,
  lat REAL, lng REAL,
  heading_deg   REAL,
  exif_json     TEXT,
  transcript    TEXT,                -- voice notes; audio is never discarded
  upload_state  TEXT NOT NULL DEFAULT 'local'
                CHECK (upload_state IN ('local','queued','uploaded','failed')),
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);

CREATE TABLE media_links (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  media_id      TEXT NOT NULL REFERENCES media(id),
  entity_type   TEXT NOT NULL CHECK (entity_type IN
                 ('observation','plant_checkin','planting_event','feature',
                  'feature_condition_log','photo_point_visit','propagation_batch',
                  'batch_event','collection_event','detection','property','zone')),
  entity_id     TEXT NOT NULL,
  role          TEXT DEFAULT 'attachment'
                CHECK (role IN ('attachment','primary','reference','before','after')),
  sort_order    INTEGER DEFAULT 0,
  created_at TEXT NOT NULL, deleted_at TEXT
);
CREATE INDEX idx_media_links_entity ON media_links(entity_type, entity_id);
```

**Storage policy:** capture at full resolution, immediately write a 1600 px long-edge working copy (~400 KB) and a 320 px thumbnail. Originals are retained on device by default with a user setting to purge originals after upload. At 1600 px, 5,000 photos is ~2 GB; at full res the same set is ~15 GB. Show the user their storage usage in settings.

### 4.11 Environmental context

Auto-attached at record time. When the user later asks "why did these die," drought and soil answer it more often than anything they typed.

```sql
CREATE TABLE env_contexts (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  lat REAL NOT NULL, lng REAL NOT NULL,
  resolved_for  TEXT NOT NULL,       -- date this context describes
  temp_c        REAL,
  temp_min_c REAL, temp_max_c REAL,
  precip_24h_mm REAL,
  precip_7d_mm  REAL,
  precip_30d_mm REAL,
  precip_90d_mm REAL,
  days_since_rain INTEGER,
  gdd_base10_ytd REAL,
  soil_mukey    TEXT,
  soil_series   TEXT,
  soil_texture  TEXT,
  soil_drainage_class TEXT,
  soil_ph       REAL,
  source_json   TEXT,
  fetched_at    TEXT,
  is_stale      INTEGER NOT NULL DEFAULT 0,   -- created offline, needs backfill
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL
);
```

**Behavior:** create the row immediately with `is_stale = 1` and only coordinates + date. A background job backfills when connectivity returns. Records created offline must never block on this.

**Sources:**
- Weather/precip/GDD: **Open-Meteo** — free, no API key, has a historical archive endpoint. ⚠ VERIFY current commercial licensing terms before shipping a paid product; free tier is non-commercial.
- Soil: **USDA-NRCS Soil Data Access**, POST to `https://SDMDataAccess.sc.egov.usda.gov/Tabular/post.rest`, which accepts raw T-SQL and returns JSON. Public-domain federal data, no key. Note: the endpoint is single-threaded with a 100,000-record / 32 MB limit per query — throttle to one request at a time with a courtesy delay, and cache aggressively by map unit. Queries without an area symbol may mix SSURGO and STATSGO records; constrain by `areasymbol`.
- Cache soil results per `mukey` — the soil under a given point does not change.

### 4.12 Devices and detections (Phase 2 — build the tables now)

The abstraction people get wrong is attaching detections to the *device*. Cameras and nodes move; a detection belongs to a **deployment**. This is the only way survey effort ever normalizes.

```sql
CREATE TABLE devices (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  device_type   TEXT NOT NULL CHECK (device_type IN
                 ('bioacoustic','trail_camera','weather_station','soil_sensor',
                  'water_level','other')),
  label         TEXT NOT NULL,
  make_model    TEXT,
  serial        TEXT,
  config_json   TEXT,
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);

CREATE TABLE deployments (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  device_id     TEXT NOT NULL REFERENCES devices(id),
  zone_id       TEXT REFERENCES zones(id),
  feature_id    TEXT REFERENCES features(id),
  lat REAL NOT NULL, lng REAL NOT NULL,
  bearing_deg   REAL,
  height_cm     REAL,
  started_at    TEXT NOT NULL,
  ended_at      TEXT,
  settings_json TEXT,
  notes         TEXT,
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);

CREATE TABLE detections (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  deployment_id TEXT NOT NULL REFERENCES deployments(id),
  detected_at   TEXT NOT NULL,
  taxon_id      TEXT REFERENCES taxa(id),
  raw_label     TEXT NOT NULL,
  confidence    REAL,
  model_name    TEXT,                -- 'BirdNET-Go 2.x', 'SpeciesNet'
  model_version TEXT,
  media_id      TEXT REFERENCES media(id),
  clip_offset_ms INTEGER,
  verified_by   TEXT,
  verified_at   TEXT,
  verification  TEXT CHECK (verification IN ('confirmed','rejected','uncertain')),
  created_at TEXT NOT NULL, updated_at TEXT NOT NULL, deleted_at TEXT
);
CREATE INDEX idx_det_deploy_time ON detections(deployment_id, detected_at DESC);
```

An ingest API accepts batches of detections keyed by `device.serial` + timestamp, resolving to the deployment active at that time. Build the endpoint contract in v1 even if nothing calls it yet.

### 4.13 Tracks

Absence of observation is data. Knowing where you *haven't* walked is half of a survey.

```sql
CREATE TABLE tracks (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  started_at    TEXT NOT NULL,
  ended_at      TEXT,
  distance_m    REAL,
  purpose       TEXT,
  geojson       TEXT,                -- LineString, simplified on save
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);

CREATE TABLE track_points (
  id            TEXT PRIMARY KEY,
  track_id      TEXT NOT NULL REFERENCES tracks(id),
  recorded_at   TEXT NOT NULL,
  lat REAL NOT NULL, lng REAL NOT NULL,
  accuracy_m REAL, altitude_m REAL, speed_mps REAL
);
```

Sample at 5 s / 10 m minimum displacement. Apply Douglas-Peucker simplification (~5 m tolerance) on save; retain raw points only for the active track. Requires an Android foreground service with a persistent notification — do not attempt background location without it.

### 4.14 Cost-share practice tracking

EQIP and TPWD PUB reporting is a real recurring pain for exactly this user, and the data is a subset of what's already captured. No competitor does this.

```sql
CREATE TABLE programs (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  name          TEXT NOT NULL,       -- 'USDA-NRCS EQIP', 'TPWD PUB'
  agency        TEXT,
  contract_ref  TEXT,
  contact_name  TEXT,
  contact_email TEXT,
  starts_on TEXT, ends_on TEXT,
  notes         TEXT,
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);

CREATE TABLE practices (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  program_id    TEXT REFERENCES programs(id),
  practice_code TEXT,                -- NRCS code, e.g. '315','338','645'
  name          TEXT NOT NULL,
  zone_id       TEXT REFERENCES zones(id),
  planned_amount REAL,
  completed_amount REAL,
  unit          TEXT,                -- 'acres','feet','each'
  planned_start TEXT, due_on TEXT, completed_on TEXT,
  status        TEXT CHECK (status IN
                 ('planned','in_progress','complete','certified','cancelled')),
  notes         TEXT,
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);

CREATE TABLE practice_activities (
  id            TEXT PRIMARY KEY,
  property_id   TEXT NOT NULL,
  practice_id   TEXT NOT NULL REFERENCES practices(id),
  occurred_on   TEXT NOT NULL,
  activity_type TEXT,                -- 'herbicide','seeding','planting','fencing'
  amount        REAL,
  unit          TEXT,
  cost_usd      REAL,
  contractor    TEXT,
  linked_entity_type TEXT,           -- optional link to planting_event etc.
  linked_entity_id   TEXT,
  notes         TEXT,
  created_by TEXT NOT NULL, created_at TEXT NOT NULL,
  updated_at TEXT NOT NULL, deleted_at TEXT
);
```

Export: per-program PDF/CSV with practice completion, dated photo evidence, and acreage — the shape an agency reviewer wants.

---

## 5. Species identification pipeline

Three layers. Each is independently optional; the app is fully usable with all three off.

**Layer 1 — Pl@ntNet (online, primary).**
REST API, 1–5 images of the same individual per request, returns ranked species with confidence 0–1. Set the `project` parameter to a regional flora rather than `all` — Pl@ntNet's docs are explicit that this improves accuracy. There's also a disease-identification route (returns EPPO codes) worth exposing as a secondary action on a sick-looking plant.

**Licensing — resolve before launch.** Pl@ntNet is a non-profit research initiative. Commercial usage beyond 500 identification requests/day is paid and requires a signed contract; rates scale down to €2/1,000 requests at very high volume, and the Pro plan bills €1,000 initially. Creating multiple free accounts from one IP is explicitly forbidden. **Action item: contact Pl@ntNet with the use case before shipping paid tiers.** They also have a beta multi-species "survey"/quadrat route, access-gated behind a use-case review — worth requesting, as it would hand us the vegetation-survey feature.

**Layer 2 — on-device model (offline fallback).**
iNaturalist's production CV model is **not** available — they keep full species classifiers private for IP reasons and because many contributors retain all rights to their photos. What they *do* publish is a set of "small" models covering ~500 taxa plus taxonomy and geographic model files, explicitly suitable for on-device use, along with large open training datasets (3.3M photos / 10,000 species from the 2021 FGVC8 challenge). Use the small model as-is for v1; a fine-tuned regional model is a later project.

**Layer 3 — LLM re-rank (the differentiator).**
Take the top candidates from layers 1–2 and re-rank them with context no vision model has: county, zone type, moisture regime, season, elevation, soil series from `env_contexts`, and the property's own species library and planting history. Store the rationale in `identification_suggestions.reasoning` and show it to the user.

**Bring-your-own-key.** The user supplies their own API key, stored in platform secure storage (`flutter_secure_storage` → Android Keystore). **Important correction to state plainly in the UI: a Claude Pro/Max subscription does not grant API access — an Anthropic API key is billed separately.** Support Anthropic, OpenAI, and a custom OpenAI-compatible base URL.

**Rules:** a machine ID is *never* written to `observations.taxon_id` without user acceptance. Confidence is always displayed. Offline captures queue for identification and process on reconnect.

---

## 6. Import and export

### Import
- **KML / KMZ** — property boundary, zones, existing pins. KMZ is a zipped KML; extract with `archive`, parse with `xml`. Map Placemark → feature or zone by geometry type, let the user assign types in a review step before commit.
- **GeoJSON / GPX**
- **CSV** for the species library, with column mapping
- **Geotagged photo folder** — read EXIF, create observations at the embedded coordinates

### Export — "Take my data" (must be a prominent, one-tap feature)

Produces a single folder or ZIP:

```
<property-name>-export-<date>/
  README.md                  # what this is, how to read it
  database.sqlite            # complete, queryable, open schema
  data/
    observations.csv
    plants.csv
    plant_checkins.csv
    planting_events.csv
    propagation.csv
    features.csv
    zones.csv
    taxa.csv
    detections.csv
    practices.csv
  geo/
    observations.geojson
    zones.geojson
    features.geojson
    plantings.geojson
    tracks.geojson
    property.kml           # opens in Google Earth
  media/
    photos/YYYY/MM/<id>.jpg   # GPS written into EXIF
    audio/...
  reports/
    survival-summary.pdf
```

**On Android**, the export folder is written to shared storage so it appears over USB (MTP) with no special software. This is a first-class supported workflow: plug the phone into a computer, drag the folder off. **On iOS** there is no MTP; route through the Files app and Finder file sharing (`UIFileSharingEnabled` + `LSSupportsOpeningDocumentsInPlace`).

**On Google Docs/Drive:** implement as a **user-initiated "Export to Drive" button**, not continuous background logging. Continuous logging means OAuth scope creep, a hard Google dependency, and a cloud copy of exactly the data the product promises to keep private — it undercuts the entire pitch. A manual push gets ~95% of the value. Note also that tabular field records belong in Sheets, not Docs; export CSV.

---

## 7. Screens

1. **Map (home)** — property boundary, zone overlays, clustered records. Layer toggles by record type. Big persistent capture FAB. Long-press to drop a record at an arbitrary point.
2. **Capture sheet** — camera → auto GPS/time/zone → species picker (with ID suggestions inline) → notes → voice note → save. Target: under 15 seconds for a bare record. Everything after the photo is optional.
3. **Feed** — reverse-chronological, filterable by zone, type, species, date range, author.
4. **Record detail** — photos, map inset, env context, edit history, related records.
5. **Plantings** — list of planting events with survival %, drill into cohort, drill into tagged individual, timeline of check-ins.
6. **Propagation** — batches with counts and status, lineage view showing mother plant → collection → batch → planting.
7. **Species** — the property's library, occurrence counts, first/last observed, gallery.
8. **Photo points** — due list, capture with ghost overlay, time-series scrubber.
9. **Features & infrastructure** — map + list, condition history, maintenance due.
10. **Programs** — practices, completion, deadlines, export.
11. **Settings** — offline maps, storage, API keys, sharing & members, export, privacy.

**Field ergonomics (non-negotiable):**
- Every primary action reachable one-handed with a thumb
- High-contrast outdoor mode; test in direct sun
- Touch targets ≥ 56 dp — the user is wearing gloves
- Never block a save on network, GPS lock, or species ID
- Batch writes and allow screen sleep between records; a phone doing continuous GPS + camera in Texas summer heat will thermally throttle

---

## 8. Build order

**Milestone 1 — Local core (no account required)**
Schema + migrations · map with offline basemap · KML import · capture flow with photo/GPS/notes · feed · zones with auto point-in-polygon assignment · species library with search · full export.
*Acceptance: install the APK on a phone in airplane mode, import the SFS boundary, walk the property, record 20 observations across 3 zones, export to USB, open the GeoJSON in QGIS.*

**Milestone 2 — Plantings and propagation**
Planting events, tagged individuals, check-ins, survival calculation, propagation batches, lineage view.
*Acceptance: record a December planting of 40 black willow cuttings traced back to a collection event from a named mother plant; check in the following March; survival rate computes correctly for both cohort-level and individual-level checks.*

**Milestone 3 — Features, photo points, tracks**
Feature types, condition logs, photo points with ghost overlay, track logging.
*Acceptance: establish a photo point, return a week later, and the overlay guides you to within 3 m and 5°.*

**Milestone 3.5 — Encrypted backup (see §11)**
Content-addressed blob store, passphrase-derived encryption, Drive appDataFolder target, restore flow.
*Acceptance: back up a populated property, factory-reset the phone, reinstall the APK, restore from passphrase alone, and verify every record and photo returns with correct coordinates and timestamps.*

**Milestone 4 — Sync and sharing**
Supabase + PowerSync, auth, memberships, invites, RLS, guest links with fuzzing.
*Acceptance: Steward invites a Guest; Guest sees fuzzed coordinates and cannot write. A Scout's edit to a Ranger's record is rejected server-side, not just hidden in the UI.*

**Milestone 5 — Intelligence**
Pl@ntNet integration, on-device fallback, LLM re-rank, env context enrichment, voice transcription.

**Milestone 6 — Programs and devices**
Practice tracking and agency export; detection ingest endpoint.

---

## 9. Open questions for Austin

1. Species library seed — ship the SFS 41-species palette as the default starter set, or a broader regional list with the 41 pre-favorited?
2. Tag code format — free text, or enforce a pattern (e.g. `SFS-BW-001`) with a scanner for QR/barcode tags?
3. Should Naturalist-role suggestions notify the Steward, or accumulate silently in a review queue?
4. Guest links: is 30-day expiry with fuzzed coordinates the right default, or too conservative for sharing with family?
5. Multi-property from day one, or single-property with the schema ready? (Schema supports multi; UI is simpler single.)

---

## 10. Risk register

| Risk | Impact | Mitigation |
|---|---|---|
| PMTiles + local HTTP server proves unstable on Android | Blocks offline maps | Timebox to 2 days; fall back to MBTiles |
| Pl@ntNet commercial licensing cost | Blocks paid tier | Contact them now; on-device model is the fallback |
| Photo storage growth on device | User runs out of space | 1600 px working copies, storage dashboard, optional original purge |
| Background location drains battery / Android kills service | Track logging unreliable | Foreground service + persistent notification; 10 m displacement filter |
| Open-Meteo commercial terms | Env context feature | Verify licensing; NWS `api.weather.gov` is a no-key fallback for forecast, less good for history |
| Supabase WAL growth with idle PowerSync | Backend outage | Check current PowerSync guidance; monitor disk |
| User forgets backup passphrase | Total, unrecoverable data loss | Recovery kit at setup; repeated warnings; optional low-security mode (§11.6) |
| Backup silently stops working | User discovers loss only when restoring | Automated verification job; nag banner after 14 days without a successful backup |

---

## 11. Encrypted backup and restore

### 11.1 Why this is load-bearing

The local-first architecture is what makes the privacy promise real. It is also what makes a phone in the creek a total loss. A user who has logged four years of check-ins on a riparian planting cannot be told "sorry."

Sync (Milestone 4) partially covers this, but only for users who create an account and accept a plaintext server-side copy. Backup must work for the **no-account, fully local user** — the default and most privacy-conscious case. Build backup before sync, not after.

### 11.2 Design constraints

Naively "zip everything and upload" fails at real data volumes. A property with 5,000 photos is ~2 GB of working copies; re-zipping and re-uploading that nightly over rural LTE is not viable and will get the user rate-limited, throttled, or billed.

The design must therefore be:

- **Incremental** — only changed content is uploaded
- **Content-addressed** — media is immutable and already has `sha256` in the `media` table; use it
- **End-to-end encrypted** — the storage provider never sees plaintext coordinates, photos, or notes
- **Resumable** — a backup interrupted at 60% resumes, not restarts
- **Verifiable** — an untested backup is not a backup

### 11.3 Structure

```
<appDataFolder>/fieldstation/
  manifest.json.enc            # small, rewritten every backup
  db/<generation>.sqlite.enc   # full DB dump, ~5-10 MB, keep last 5 generations
  blobs/<sha256[0:2]>/<sha256>.enc   # one per media file, write-once
```

The database is small enough (10,000 observations with notes and history is well under 10 MB) to dump whole every time. **Media blobs are write-once and never rewritten** — a photo taken in 2026 is uploaded exactly once, ever. This is what makes incremental backup work: the nightly delta is one DB dump plus whatever photos were taken that day.

The manifest holds the schema version, generation number, blob inventory with sizes, device ID, and timestamp. It is the only file that needs a consistent read.

### 11.4 Cryptography

**Do not hand-roll this.** Use libsodium bindings (`sodium_libs`) rather than assembling primitives.

- **Key derivation:** user passphrase → **Argon2id** (libsodium `crypto_pwhash`, `MODERATE` limits — tune so derivation takes ~1 s on a midrange Android phone) → 32-byte master key. Salt is random per-property, stored in plaintext alongside the manifest.
- **Master key wraps a per-backup data key** so the passphrase can be changed without re-encrypting every blob. Store the wrapped data key in the manifest header.
- **File encryption:** XChaCha20-Poly1305 via libsodium's **secretstream** API. This is designed for exactly this — chunked, streamed, authenticated encryption of large files, with resumability and tamper detection per chunk. Chunk at 1 MB.
- **Each blob gets a random nonce.** Never reuse.
- **Filenames leak information** — a blob named for its plaintext sha256 tells an observer whether you have a specific known file. Name blobs by `HMAC-SHA256(master_key, sha256)` instead, so filenames are meaningless without the key.
- The master key lives in platform secure storage (`flutter_secure_storage` → Android Keystore / iOS Keychain) so routine backups don't prompt for the passphrase. The passphrase is required only for setup and restore.

### 11.5 Storage targets

Destination is pluggable. Ship these:

| Target | Scope / mechanism | Notes |
|---|---|---|
| **Google Drive** | OAuth scope `drive.appdata` only | Writes to the hidden app data folder. Invisible in the user's Drive UI, doesn't clutter it, and — critically — this scope grants **no access to the user's other files**. Do not request full Drive scope; it's a worse permission prompt and an unnecessary liability. |
| **iCloud** | CloudKit private database, or iCloud Drive ubiquity container | Private DB is encrypted in transit and at rest by Apple; our payload is already encrypted regardless. |
| **Any S3-compatible** | User supplies endpoint, bucket, keys | For self-hosters. Cheap to add, disproportionately loved by the technical segment. |
| **Local folder / USB** | Existing export path | Same encrypted structure written to shared storage. |

Note: **Android Auto Backup caps at 25 MB per app** and is not a substitute for anything here. Explicitly exclude the media directory and the SQLite file from Auto Backup via `android:fullBackupContent` rules so the OS doesn't silently ship partial data around.

### 11.6 Key recovery — be honest about the tradeoff

Real end-to-end encryption means **if the user loses the passphrase, the data is gone and we cannot help.** Do not soften this in the UI.

At setup, generate a **Recovery Kit**: a 12-word BIP-39 recovery phrase that independently unwraps the data key, presented on a screen the user is prompted to screenshot, print, or save to a password manager. Two independent paths (passphrase, recovery phrase) is the right balance — more paths means more attack surface.

Offer an explicit, clearly-labeled **"convenience mode"** for users who'd rather risk provider access than risk losing everything: the data key is additionally wrapped with a key held in the user's cloud account keychain, so restore needs only the account login. State plainly what this trades away. Default is off.

### 11.7 Schedule and behavior

- Automatic when **charging + on Wi-Fi**, at most once daily. Never back up over cellular unless explicitly enabled — rural LTE is often metered.
- Manual "Back up now" always available.
- DB dump runs against a consistent snapshot (SQLite `VACUUM INTO`, which produces a clean single-file copy without blocking).
- Upload queue is persistent and resumable across app restarts.
- Retain the last 5 DB generations. Blobs are never deleted by the backup process; a separate, explicitly user-initiated "prune orphaned blobs" action handles media the user has deleted, with a 30-day grace period.

### 11.8 Verification — the part everyone skips

Weekly, automatically: download the manifest and one random blob, decrypt both, verify the authentication tag and the plaintext hash. Record the result.

Surface **"Last verified backup: 3 days ago"** in settings, and show a persistent (dismissible) banner if no successful backup has completed in 14 days. Most backup systems fail silently and are discovered dead at exactly the wrong moment.

### 11.9 Restore flow

1. Fresh install → "Restore from backup"
2. Choose provider, authenticate
3. App lists available backups (property name, record count, date, size) — decrypted from the manifest after passphrase entry
4. Enter passphrase or recovery phrase
5. **Database restores first** (seconds to a minute). The app is immediately usable — every record, coordinate, and note is present, with photos showing placeholders.
6. **Media streams in the background**, most-recent-first, resumable. User can browse and record new observations while it runs.
7. Offline map tiles are *not* backed up (they're re-downloadable and would dominate backup size). Prompt to re-download after restore.

Step 5 matters more than it looks. A restore that makes the user stare at a progress bar for 40 minutes before they can do anything feels like data loss even when it isn't.

### 11.10 Acceptance criteria

- Back up a property with 500 observations and 1,000 photos; confirm the second backup uploads only the delta.
- Kill the app mid-upload; confirm resume, not restart.
- Factory-reset the device, reinstall, restore from passphrase alone; verify every record, coordinate, timestamp, tag code, and photo returns intact, and that EXIF GPS survived the round trip.
- Confirm the storage provider's web UI shows only opaque encrypted blobs with non-identifying filenames.
- Enter a wrong passphrase; confirm a clean failure with no partial-write corruption of local data.
