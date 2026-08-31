# Competitive deep dive — 2026-08-31

Seven apps Austin flagged, examined for: are they competitors, what can we do
that they can't, and what do they have that we should steal at some level.

The one-line conclusion first: **nobody is building our app.** Every product
here is either a professional forestry tool (timber as inventory), a
citizen-science network (observations as public data), a reference utility,
or a UK planning platform. The private landowner doing restoration —
someone who needs *memory* of their own ground, owns their own data, and
answers to a cost-share program rather than a mill — falls between all of
them. That's our seat, and it's empty.

---

## The seven

### 1 · Forestry Sources (Trimble) — not a competitor
Parcel prospecting for industrial wood buyers: browse land parcels, evaluate
standing timber remotely, fill wood orders. Part of the Forestry One
platform. Its user is acquiring *other people's* land value; ours is tending
their own. Nothing to take except a reminder that offline parcel maps are
table stakes.

**Steal:** nothing structural.

### 2 · The Land App (UK) — the closest thing to a competitor, on the wrong continent
Desktop-first mapping for estates and regenerative agriculture: data-layer
appraisal, habitat connectivity calculators, LIDAR water-flow analysis,
"Wild Edges" automated habitat suggestions, grazing plans, offline mobile
companion that syncs photos to map features. Free tier; £16–32/user/month.
UK-centric datasets (DEFRA schemes, OS maps) — largely useless in Lampasas
County.

This is what "land management as planning" looks like done well. But it's a
*plans-first* tool: you draw intentions on a desktop map. Ours is
*record-first*: you capture what happened standing in the field. Both are
real workflows; theirs breaks without the UK data spine.

**Steal:** the idea that a boundary+zones map can *propose* things
(their Wild Edges). At basic level: our zones already exist — a "zone
report" (area, records, survival, species mix per zone) is cheap and reads
like their appraisal output. Water-flow overlay from LIDAR is a Long Watch
/ desktop job someday, not phone work.

### 3 · iNaturalist — not a competitor; a *neighbour* we should connect to
The world's observation network: computer-vision ID (now offline, in-camera,
Seek-style, with models refreshed ~monthly), community verification to
research grade, data flowing to GBIF. It is better than we will ever be at
"what species is this?" — that's fine, because it's structurally incapable
of being our app: observations are public-by-default (coordinate obscuring
is a flag, not a philosophy), there's no tenure, no management history, no
lineage, no "the 40 cuttings from that mother plant," no privacy of a
working ranch.

**Steal, at two levels:**
- **Basic:** their UX pattern of *suggest-in-camera*. Our ID flow asks you
  to pick a photo then wait; theirs suggests while you frame. Ours can't
  match offline CV with BYO-key cloud ID, but the interaction lesson stands:
  put the suggestion where the decision happens.
- **Feature:** an **"export to iNaturalist" action** (opt-in, per record,
  coordinates obscured) would let a steward contribute selected
  observations to science without living in two apps. Their API supports
  it. This converts them from competitor-adjacent to distribution channel —
  every iNat power-user with acreage is our exact customer.

### 4 · SoilWeb (UC Davis + NRCS) — a utility we already quietly subsume
GPS → SSURGO soil profile: taxonomy, depth profiles, drainage, suitability
ratings. Beloved, free, single-purpose. We already query the same SDA
backend (D-022, opt-in, coarsened) and *attach it to records*, which SoilWeb
can't — it has no memory.

**Steal (basic level):** a **"soil under me" tool** — tap the map or your
position, get the SoilWeb-style card (series, texture, drainage) from our
existing SDA client + cache. One screen, huge field utility, and it makes
the D-022 opt-in worth switching on. Respect the same privacy gate.

### 5 · Plot Hound (SilviaTerra/NCX) — competitor for one workflow: structured monitoring
Free cruising app: navigate to predefined plots, enter tree data with custom
fields and validation rules, works fully offline, syncs to Canopy for
analysis. Team collaboration. Its brilliance is the *protocol*: fixed plots
+ navigation + structured entry = defensible inventory. Its world is timber
volume, not restoration.

**Steal (feature level):** **monitoring protocols.** We have photo points
(return-visit ghost overlay — arguably better than anything Plot Hound has)
but no *plot revisit* concept: "stand here every February, count stems,
same 10 questions." A lightweight protocol = a saved location + a form +
a revisit cadence. This is also exactly what TPWD/EQIP compliance wants.
Our capture form is free-form; theirs validates. A per-protocol required-
fields check is cheap and raises data quality where it matters.

### 6 · Texas Forestry BMPs (TX A&M Forest Service) — reference app, ally not competitor
The BMP handbook plus five field tools: soils identifier, slope tool, tree
height tool, culvert sizing, pictorial directory. Static content, regional,
free.

**Steal (basic level):** the **pocket instruments**. Slope and tree height
from phone sensors (clinometer math) are an afternoon each, work fully
offline, and make the app the only thing you carry. A "references" shelf
(BMP-style guidance, planting windows, our own species plates — which we
already have!) fits the R&D-library instinct Shorts already lives by.

### 7 · WoodsApp (Bitcomp, Finland/EU) — competitor's shadow; we already own the answer
Cloud platform: Copernicus satellite monitoring + AI, damage alerts
(storm/drought/health), harvest planning, task management for owners and
service organisations. European data spine, subscription, cloud-first —
the philosophical opposite of us (your forest lives on their servers).

**The kicker: Austin already built the core of this.** Long Watch does
Sentinel-2 zone NDVI with burndown visible from orbit. WoodsApp proves
there's a product there. The move is not to clone their cloud — it's
**Long Watch alerts surfaced in Field Notes** (or its desktop): "Section 04
NDVI dropped 18% vs last August." Satellite watching *your own zones*,
computed by *your own instrument*, no third party holding your maps.
Nobody else can offer that combination at any price.

---

## The scoreboard

| Capability | FS | Land App | iNat | SoilWeb | Plot Hound | TX BMP | Woods | **Field Notes** |
|---|---|---|---|---|---|---|---|---|
| Offline-first capture | ◐ | ◐ | ◐ | ✗ | ✓ | n/a | ✗ | **✓** |
| No account required | ✗ | ✗ | ✗ | ✓ | ✗ | ✓ | ✗ | **✓** |
| You own the data (export, open formats) | ✗ | ◐ | ◐ | n/a | ◐ | n/a | ✗ | **✓** |
| Encrypted backup, zero-knowledge | ✗ | ✗ | ✗ | n/a | ✗ | n/a | ✗ | **✓** |
| Plant lineage (mother→batch→survival) | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | **✓** |
| Photo points w/ ghost overlay | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | **✓** |
| Species ID | ✗ | ✗ | ✓✓ | ✗ | ✗ | ✗ | ✗ | ◐ (BYO key) |
| Soil at a point | ✗ | ✗ | ✗ | ✓✓ | ✗ | ◐ | ✗ | ◐ (attached, not browsable) |
| Structured plot monitoring | ✗ | ✗ | ✗ | ✗ | ✓✓ | ✗ | ✗ | ✗ |
| Satellite change alerts | ✗ | ✗ | ✗ | ✗ | ✗ | ✗ | ✓✓ | ✗ (Long Watch exists, unintegrated) |
| Field instruments (slope, tree height) | ✗ | ✗ | ✗ | ✗ | ◐ | ✓✓ | ✗ | ✗ |
| Cost-share evidence (EQIP/TPWD) | ✗ | ◐ (UK schemes) | ✗ | ✗ | ✗ | ◐ | ✗ | ◐ (programs exist; no packet) |

Legend: ✓✓ best-in-class · ✓ solid · ◐ partial · ✗ absent.

**Things we do that no one on this list does:** the whole left spine —
offline + no account + owned data + encrypted backup — plus lineage and
photo points. That spine is the moat; it cannot be retrofitted onto a
cloud platform without destroying their business model.

**Things they do that we don't, ranked by fit:**
1. Structured revisit protocols (Plot Hound) — closest to our core.
2. Soil-under-me browser (SoilWeb) — nearly free given D-022 plumbing.
3. Pocket instruments (TX BMPs) — cheap, offline, delightful.
4. Satellite alerts (WoodsApp) — we own the pipeline already; integration.
5. In-context ID suggestions + iNat export (iNaturalist) — interaction
   polish and a distribution channel.
6. Zone appraisal reports (Land App) — derives from data we already hold.

None of the seven require chasing. All the theft is at the feature level,
and every stolen feature lands *inside* our privacy spine rather than
compromising it.
