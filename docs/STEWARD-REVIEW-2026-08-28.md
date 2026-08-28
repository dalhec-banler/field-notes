# The app judged as a restoration steward's tool — 2026-08-28

Not a code audit. This is the app read the way the person who actually
does the work reads it: someone restoring a river reach, collecting seed
from their own ground, growing it out, planting it, and having to prove
years later that any of it worked.

## What already serves that person well

- **Capture is honest and fast.** Photo, GPS, species, notes, voice — under
  fifteen seconds, and it never lies about location. The `-1` unlocated flag
  instead of a fake coordinate is exactly right for data you'll still trust
  in 2032.
- **The lineage exists in the schema.** mother plant → collection → batch →
  planting → tagged individual → check-in is modelled properly, and survival
  is derived rather than stored. Very few tools get this right.
- **Continuity tooling is real.** Photo points with a ghost overlay and a
  history scrubber are the strongest feature in the app.
- **The record is yours.** Full export in open formats, encrypted backup
  with a recovery phrase, nothing leaving the phone by accident.

## Where it fails the steward

### 1. You cannot record collecting seed. At all.

This is the biggest gap and it isn't close. `source_plants` and
`collection_events` are in the schema with the right columns —
`material_type` (seed, cutting, division…), `quantity`, `collected_on`,
`collector`, lat/lng, and `is_on_property`/`origin_notes` for offsite
provenance — and **neither has a screen**. They are created invisibly, as a
side effect of starting a propagation batch, from one free-text "source
label" box, with `material_type` hardcoded to `'hardwood_cutting'` and
`collected_on` forced to today.

So the steward cannot:
- record a collection as its own act, in the field, at the moment it happens;
- collect in October and decide in December what to sow;
- say what they collected — seed, cuttings, divisions, whole plants;
- record how much, from which plant, with whom, in what condition;
- ever find that mother plant again.

A restoration operation runs on this. It is the front half of the whole
workflow, and the app starts at the back half.

### 2. Phenology is modelled and never asked for.

`observations.phenology` exists with a proper enum — vegetative, budding,
flowering, fruiting, **seeding**, senescent, dormant, dead — and nothing in
the UI ever sets it. Same for `count_estimate`. For a seed collector,
phenology *is* the calendar: the entire year is organised around who is
ripe when. Every walk currently throws that observation away.

### 3. Nothing tells you what to do this week.

Photo points carry `next_due_on` and nothing surfaces it but their own
list. Practices have deadlines that only appear inside Programs. There is
no single answer to "what needs doing" — which is the question a steward
actually opens the app with, standing at the truck.

### 4. Zones are drawn but aren't work units.

Zones import, render and auto-assign records correctly, and then do
nothing. There's no zone view — no "Section 3: 47 records, 12 species, 3
plantings, 78% survival, last walked 12 days ago". Restoration is organised
by unit of ground, and the app has no page for a unit of ground.

### 5. Survival is recorded but teaches nothing.

The data to answer the only question that matters — *what actually
survives here* — is all present: stock source, protection, zone, planting
month, species, check-ins. Nothing compares them. A steward with four years
of plantings should be able to learn that November bareroot under cages hit
80% in the riparian zone and 30% on the upland, and plant accordingly. Right
now they'd have to export to a spreadsheet to find out.

---

## Proposals — ranked, for discussion

### A. The seed year (the headline)

**Collection as a first-class act.** A capture type that records material
(seed / cutting / division / transplant / whole plant), quantity, the mother
plant, who collected, and where — in the field, in seconds, offline. It
becomes a `collection_event`, and a batch can be started *from* it later, or
never.

**A mother-plant registry with a map layer.** `source_plants` already has
lat/lng and `is_on_property`. Give it a screen and a pin: the willows you
cut from, the madrone that sets good seed, the offsite population near
Terlingua with its provenance note. Returning to a known individual is the
whole game, and the ghost-overlay machinery already exists to photograph it
the same way each year.

**Phenology on the capture form** — one row of chips, only for plant
records. Cheap to build, and it's the raw material for everything below.

**Seed lots.** A collection becomes a lot you can clean, weigh, test, store
and stratify, with a location ("shed fridge, bin 3") and a stratification
window that shows up when it ends. *This one needs new schema* — a
`seed_lots` table and lot events — so it's a D-0xx decision, not a quiet
addition.

**Phenology memory — the thing nobody else can do.** Once two seasons of
phenology are recorded, the app knows *your* ground: "*Bouteloua
curtipendula* was seeding 12 Oct last year and 3 Oct the year before —
it's 28 Sep, go look." Not a generic almanac; your plants, your reach, your
elevation. This is the feature that would make somebody put the app down and
say nobody else has this.

### B. This week

One surface that answers "what should I be doing": photo points due,
practice deadlines, stratification windows ending, check-ins overdue on a
planting cohort, collections likely ripe (from A). Sorted by what's on the
ground you're standing on. This is the screen a steward would open first,
and it costs little because every input already exists.

### C. Zone as a work unit

Tap a zone: what's in it, what's planted, how it's doing, when you were last
there, what's due. Restoration budgets, grant reports and Saturday mornings
are all organised by unit of ground.

### D. Survival that teaches

A comparison view over cohorts: by stock source, protection, planting month,
zone, species. "Cages beat no cages by 34 points here" is a finding worth
four years of check-ins. The data model already supports every axis; this is
query and presentation, no schema change.

### E. The evidence packet

Programs and practices are already modelled. Generate the thing an agency
actually wants: a dated packet of practice, acreage, species, counts,
photographs with EXIF coordinates, and survival — the proof that the work
happened. Turns a compliance chore into a one-tap export.

---

## What I'd build first, if it were my call

**A, in this order:** phenology chips on the capture form (an afternoon, and
it starts accruing data immediately — every week we wait is a week of
phenology lost), then collection-as-a-capture with the mother-plant
registry and map layer, then **B (This week)**. Those three turn the app
from a good field journal into the thing that runs the operation.

Seed lots and phenology memory are the next tier and need decisions:
seed lots because it's new schema, phenology memory because it's only
honest once there are two seasons behind it.

**D** is the cheapest impressive thing in the list — no schema, high payoff
— and worth slotting in whenever there's a gap.
