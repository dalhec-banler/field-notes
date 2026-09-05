# Design — Field Notes

The code has been citing a "design README §3.x" that did not exist in this
repository; the external audit noticed, and it was right that the mark
language had no written home. This is that home. It records what is
already built and decided, so a reader — or a future contributor — can
tell a deliberate choice from an accident.

Constraints live in `CLAUDE.md`, decisions in `DECISIONS.md`. This file
describes only how the thing looks and behaves.

## The voice

Plain, field-worn, said out loud. "No GPS fix — flagged, never faked."
"Nothing has left the phone." "The chain tolerates a break at either end."

Never "Error occurred" or "Successfully saved". A message says what
happened and, where it matters, what to do next. Errors name the move:
"No signal here — your photos are safe on this phone; ask again from the
record when you have coverage."

## Skins (D-023)

Two: **quiet** by default, **press** — paper, ink, oxblood — found by
seven taps on the version row. A skin is a look. It never changes field
ergonomics: `Metrics.touchMin` is 56, the shutter is 86, the FAB is 66, in
both skins, because gloved thumbs in the sun get the same targets either
way.

Colour comes from tokens (`theme/tokens.dart`). No widget names an ink
literal. The two principled exceptions are the print palette (`PlateInk`,
which must print the same from either skin) and map furniture that has to
read on satellite imagery.

## The mark language

One table, `map/record_ink.dart`, read by the phone map, the desk map, the
export plate, the HTML export and the list rows. Three surfaces used to
disagree about what colour a record was; they cannot now.

**Shape says what kind of thing it is. Colour says the domain. Size and
halo say which layer it belongs to.**

| Record type | Shape | Ink |
|---|---|---|
| plant | circle | growth-form greens; sage when unnamed |
| phenology | circle | moss |
| wildlife / sign | circle | ochre / ochre-light |
| water | circle | river |
| soil | circle | umber |
| general | circle | warm gray |
| infrastructure | square | ink |
| maintenance | square | ochre |
| problem | triangle | oxblood |

Records wear a **paper** stroke. Features — springs, guzzlers, headcuts —
wear the same silhouettes at a larger size with a **white halo**, so the
two layers read apart at a glance even where they overlap. Clusters are an
ink disc with a paper ring and a count, capped at 99+. Your own position is
a signal-blue view-finder reticle that nothing else on the map may borrow,
inside a translucent ring showing the fix's accuracy on the ground.

Photo points are ochre camera bugs with the ground they frame drawn as a
wedge: the field of view derived from focal length, out to the station's
stated extent. A station that has never been shot draws as a bug alone —
it does not yet claim to look anywhere.

Sections everywhere records are listed follow the same taxonomy
(`RecordRealm`): **Species** (anything with a name), **Observations**,
**Infrastructure**, **Problems**. A fence post is not a species.

### One thing to know about map icons

`addImage` registers bitmaps at density 1. Every icon is therefore drawn
at 3× and given `iconSize: 1/3`, and its dimensions in the source are
DEVICE pixels. This has bitten three separate marks (cluster badges,
feature markers, record shapes) — each looked correct in code and
microscopic on the phone.

## Screens

**Phone** — Map · Ledger · Grow · Species · Settings, with the capture
shutter always present.

- **Map** is the home. Chrome cards over full-bleed imagery: the place
  (tap to switch), track toggle, zone editor, area capture, layers, GPS.
  Long-press places a record at that point.
- **Ledger** is the record of entries, and it is also **the filter**: its
  chips narrow the ledger and the map together, and the map says so with
  a banner it can be cleared from.
- **Grow** holds plantings, propagation and photo points.
- **Capture** is three steps — shutter, form, notes — and never blocks on
  GPS, network or identification. A dirty capture always asks before it
  is dropped.

**Desk** — the same five, in the same order, plus **Review** and
**Export**. Ledger, Grow and Species are literally the phone's screens;
Map and Review are the desk's own. The desk edits, refines and publishes;
the phone originates (D-024).

## The plate

An export is one letter, tabloid or poster sheet: map on top, then legend,
zone table with swatches, features, records, notes, and a source line that
names the imagery. What the workspace previews IS the document — the same
page, redrawn as you toggle layers, with no separate "draw" step.

Records are off by default on every export, because they carry the exact
coordinates of private land (hard rule 3). Turning them on says so next to
the switch.

## Imagery

Esri World Imagery by default (sharp to z19), USGS filling gaps; USGS Topo
and the USGS quad blend are available as plate bases. Only public-domain
tiles — USGS and NAIP — are ever written to disk for offline use, because
Esri's terms allow display and not storage.
