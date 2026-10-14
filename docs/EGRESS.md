# Egress — everything that leaves the phone

D-038 item 4. Every HTTP request the app makes on its own goes through one
client, `FieldNetwork` (`app/lib/services/field_network.dart`). Before a
socket opens, the host is checked against `kEgressAllowlist` in that file
(or against the purpose's own rule, below), and the request is noted in
Diagnostics as `egress <host> <purpose>` — host and purpose, never the
path or the query, because the query is where coordinates, keys and tokens
ride. Anything that fails the check throws `EgressBlocked` and nothing was
connected.

`test/field_network_test.dart` walks the allowlist and fails if a host on
it is missing from this page. Adding a host is a decision: say what leaves
and what gates it, here, in the same commit.

The standing rules this page is written against:

- **Hard rule 3:** nothing leaves the device without the user's explicit
  action or an explicit setting.
- **D-022:** a record's full-precision coordinate never leaves. Where a
  location is sent at all it is rounded to two decimal places (~1.1 km)
  first. The stored row keeps the true coordinate; only the rounded one is
  put on the wire.
- **D-016:** bulk transfers wait for Wi-Fi unless the user allows cellular
  (Settings → Network). `FieldNetwork` holds the policy: purposes marked
  *bulk* are refused at the socket on blocked cellular, and the "use data
  this once" button grants an hour. Drive and relay carry both a few rows
  of sync and a hundred photos through the same target, so for those the
  engine (`BackupService`, `SyncService`) asks `FieldNetwork.bulkVerdict()`
  before media moves rather than the gate deciding per request.

## Scopes

| Scope | Where the purpose may go |
|---|---|
| allowlist | an exact host on `kEgressAllowlist`, or `*.suffix` |
| `local` | loopback only (127.0.0.0/8, ::1, `localhost`) |
| `lan` | loopback or a private address: RFC 1918, link-local, 100.64/10 (CGNAT, Tailscale), IPv6 ULA/link-local. A name like `my-mac.local` is not an address and is refused. |
| user-addressed | any host the user typed in themselves. Plaintext `http://` is refused unless the host is private or loopback, for every scope. |

## The inventory

Purpose names are what the Diagnostics log shows. "Setting" is the thing
that has to be true for the request to happen at all.

### Environmental context (D-022)

| Host | Purpose | What leaves | What never leaves | Setting |
|---|---|---|---|---|
| `archive-api.open-meteo.com` | `weather` | the record's coordinate **rounded to 2 dp**, a 30-day date window | the true coordinate, any record content | `env_context` pref (Settings → Environmental context), **off by default** |
| `sdmdataaccess.sc.egov.usda.gov` | `soil` | the same rounded coordinate inside an SQL query for the map unit | as above | same switch |

Code: `services/env_context.dart`. Rows are created locally while the
switch is off; turning it on later backfills without anything having been
sent in the interim. `sdmdataaccess.sc.egov.usda.gov` is also the soils WMS
used by export plates (below) — one host, two purposes.

### Google Drive backup and sync (D-021, D-024, D-028)

| Host | Purpose | What leaves | What never leaves | Setting |
|---|---|---|---|---|
| `*.googleapis.com` (`www.googleapis.com`) | `drive` | sealed blobs with HMAC names into the app's hidden `drive.appdata` folder; a plaintext manifest envelope (generation, timestamps, no coordinates) | the data key, the passphrase, any plaintext row or photo | the user tapped Connect on the Backup screen once (`drive_email` pref set); automatic runs also need `drive_auto_backup` / sync configured |
| `*.googleapis.com` (`oauth2.googleapis.com`) | `drive-auth` | desk only: OAuth code, PKCE verifier, refresh token, the desktop client id | — | the user tapped Connect on the desk |

Code: `backup/drive_target.dart`, `backup/drive_desktop_auth.dart`,
`desktop/drive_watch.dart` (desk reads the manifest envelope on a timer,
non-interactive, only when Drive is connected). Scope is `drive.appdata`
and nothing else.

**Native, not routed through `FieldNetwork`:** on Android the sign-in
itself is `google_sign_in` (Credential Manager / Play Services). It talks
to `accounts.google.com` and `*.googleapis.com` on Google's own stack to
obtain the token; nothing of the journal is in that exchange. It runs only
from `DriveAuth.accessToken()`, never at launch (D-021). On the desk the
consent page `accounts.google.com/o/oauth2/v2/auth` is opened in the
system browser (`url_launcher`), and the browser comes back to a one-shot
listener on `127.0.0.1`.

### The relay (D-031)

| Host | Purpose | What leaves | What never leaves | Setting |
|---|---|---|---|---|
| `relay.fieldnotes.app` | `relay` | the same sealed store as Drive, plus the control plane: property name, member display name and optional email, device id and label, join codes, org key | the passphrase, the data key, plaintext rows | the owner shared the property, or the member joined with a code (`shared_properties` in prefs) |
| whatever the user set as `relay_url` | `relay-custom` (user-addressed) | as above, to a relay of their choosing | as above | the user changed the relay address in Settings |

Code: `backup/relay_target.dart`, `sync/sharing_service.dart`,
`sync/sync_service.dart`. The default host is on the allowlist; any other
host is logged as the user's own.

### Backup to a computer on your network (D-019)

| Host | Purpose | What leaves | What never leaves | Setting |
|---|---|---|---|---|
| the paired computer's address (`lan` scope: private or loopback only) | `lan` | sealed blobs with HMAC names, a bearer code the desk displayed | plaintext anything; nothing touches the internet | the user scanned or typed the pairing code (`lan_host` / `lan_code` prefs) |

Code: `backup/lan_target.dart`. The desk side (`backup/lan_receiver.dart`)
is a server, not a client: it listens on the LAN and never originates a
request.

### Species identification (D-020)

| Host | Purpose | What leaves | What never leaves | Setting |
|---|---|---|---|---|
| `my-api.plantnet.org` | `plantnet` | up to five photographs, the chosen organ, the user's **own** API key; the key probe on save sends the key and an empty request | location, notes, any other record | the user pasted a Pl@ntNet key and asked for an identification |
| `api.anthropic.com`, `api.openai.com` | `llm` | one photograph, a prose context: county/state, zone name, soil series, month, species already recorded or planted on the property, the Pl@ntNet candidates, and the coordinate **rounded to 2 dp**; the user's own key | the true coordinate | the user entered an LLM key and asked |
| the base URL the user typed | `llm-custom` (user-addressed) | as above, to an OpenAI-compatible server of their choosing (`http://` allowed only to a private address, e.g. a box at home) | as above | provider set to Custom with a base URL |
| `api.inaturalist.org` | `inat` | **range check:** a candidate name, a 50 km radius, the coordinate rounded to 2 dp; **state list:** the state's iNaturalist place id and nothing else | the true coordinate, photos | range check: `range_check` pref, **off by default**; state list: the user tapped "Get the state's list" |

Code: `id/plantnet_client.dart`, `id/llm_client.dart`,
`id/range_check.dart`, `species/region_library.dart`. The bundled state
palettes (D-034) load from assets and make no request.

`my.plantnet.org/account/settings` is opened in the system browser from
Settings so the user can fetch their own key; the app does not request it.

### Maps

| Host | Purpose | What leaves | What never leaves | Setting |
|---|---|---|---|---|
| `build.protomaps.com` | `basemap` (bulk) | Range requests into the daily planet archive for the tiles covering the area the user framed | — | the user framed an area and tapped Capture |
| the `.pmtiles` link the user pasted | `basemap-link` (user-addressed, bulk) | a whole-archive download with resume | — | the user pasted a link on Offline maps |
| `imagery.nationalmap.gov` | `imagery-capture` (bulk) | the bbox of each tile over the captured area (NAIP, public domain) | — | rides along with Capture |
| `basemap.nationalmap.gov`, `server.arcgisonline.com` | `satellite` | z/x/y of each tile the map is looking at, proxied through the loopback tile server; Esri tiles are passed through uncached per their terms | — | the map is open with the satellite layer on; `imagery_source` pref picks which |
| `127.0.0.1` | `local` | nothing — this is the app's own tile server | | always allowed, loopback only |

Code: `map/area_downloader.dart`, `map/pmtiles_reader.dart`,
`map/basemap_manager.dart`, `map/imagery_capture.dart`,
`map/tile_server.dart`.

**Native, not routed through `FieldNetwork`:** when the map has no offline
store, or on the desk, the MapLibre style names the imagery template
directly and the maplibre native layer fetches tiles from
`basemap.nationalmap.gov` or `server.arcgisonline.com` itself. Each request
is the z/x/y of a tile in view, which is a location at tile resolution; the
same is true of the proxied path. That is the only location-shaped egress
that is not coarsened, and it is inherent in showing a map of where you
are. Vector tiles never leave the loopback server (`pmtiles://127.0.0.1`).
The HTML export loads `maplibre-gl` from `unpkg.com` **when the exported
file is opened in a browser**, not from the app.

### Export plates

| Host | Purpose | What leaves | What never leaves | Setting |
|---|---|---|---|---|
| `basemap.nationalmap.gov` (imagery, topo, imagery+topo), `server.arcgisonline.com` (when Esri is the imagery source) | `plate` | z/x/y of the tiles under the plate frame | records (off by default on every export; see DESIGN.md) | the user previews or exports a plate on the desk |
| `hydro.nationalmap.gov`, `carto.nationalmap.gov`, `sdmdataaccess.sc.egov.usda.gov` | `plate` | the framed bbox for the NHD, contours and soils overlays | — | the overlay is toggled on |

Code: `export/map_plate.dart`, `desktop/export_workspace.dart`,
`desktop/desk_map_view.dart`. A plate frame is the property's extent at
tile resolution — the same shape as the live map.

### Importing a map by link (D-036)

| Host | Purpose | What leaves | What never leaves | Setting |
|---|---|---|---|---|
| `www.google.com` (My Maps `?mid=`) or any `.kml`/`.kmz` link | `kml-link` (user-addressed) | a GET for the file | — | the user pasted the link |

Code: `screens/kml_import_screen.dart`.

## What makes no request

- `services/property_locator.dart`, `geo/*`: state resolution is bundled
  polygons; the centroid is set from a fix or a boundary. Offline.
- `services/location_hub.dart`, `track_recorder.dart`: GPS. On Android the
  fused provider may consult Play Services' network location — an OS
  matter the app does not control and does not ask for.
- `connectivity_plus`: reads the interface state locally.
- `Diag`: the diagnostics log never leaves the device unless the user
  copies or shares it.
- `url_launcher`: opens the system browser on a page; the app sends
  nothing itself.

## Reading the log

Settings → About → Diagnostics. A line looks like

    2026-10-13T18:04:11Z  FieldNetwork  egress archive-api.open-meteo.com weather

Repeats of the same host and purpose inside a minute are counted rather
than written — a capture is thousands of tiles — and the count lands on
the next line for that pair: `egress imagery.nationalmap.gov
imagery-capture (and 2140 more)`. A refused request is not an egress line;
it surfaces as the `EgressBlocked` error wherever the caller reported it.
