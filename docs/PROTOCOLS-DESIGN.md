# Monitoring protocols — design (D-033, 2026-09-15)

Austin, after UT Austin's Field Sampling Methods course and the Hornsby Bend
/ USGS / TxGIO internship list: "make sure to get all the field sampling
stuff done … I don't want the app to feel too overly academic for the lay
person, but it should definitely be able to extend to academics if the user
desires." COMPETITIVE-2026-08-31 §5 named the gap: photo points return you
to a place, but nothing returns you to a place *with a form*.

## What the outside world asks for

Nobody — a 1-d-1 appraisal district, an NRCS conservationist, a course
instructor — wants a novel method. They want a **fixed place, a named
method, a date, a repeat**, and something that lays on a table.

- **TPWD wildlife-management use (1-d-1).** Seven practices, ≥3 a year; the
  CAD may ask for the annual report with documentation. Habitat Control lists
  "Vegetation Surveys"; Census wants results "recorded on appropriate forms
  as evidence": spotlight counts, browse surveys (≥30 twelve-foot plots),
  point counts, song-bird transects. Deer summary sheet wants per-route rows.
- **NRCS / EQIP.** 528 Grazing Management: "monitoring with appropriate
  protocols and records… key areas, key plants… documented." 314 Brush
  Management: a monitoring plan naming variables, timing, frequency;
  success judged by post-treatment regrowth. 391/612 survival checks are
  already `plant_checkins` (D-018). NRI and BLM AIM share one kit: line-point
  intercept, gap intercept, height, soil stability, photo points.
- **The methods** (Herrick et al. 2017 Monitoring Manual; Daubenmire 1959;
  Braun-Blanquet; Robel 1970; Matsuoka et al. 2014; IIRH v5) are old, few,
  and free. LandPKS LandCover shows the lay framing works.

## Schema (v10) — three tables, every run is a record

`protocols` (the questions: `fields_json`, lay `name`, `method_name` fine
print, `site_kind` point|line|plot|route, `cadence_days`, `season_hint`,
`computes_json`, `is_template`, `is_starter`); `protocol_sites` (the fixed
place: origin lat/lng, `bearing_deg`, `length_m`, `radius_m`, derived
`geojson`, `marker`, `photo_point_id`, `next_due_on`, `retired_on`);
`protocol_runs` (one visit: `observation_id`, `started_at`/`ended_at`,
`observer_name`, `status` complete|partial, `values_json`, `track_id`).

`observations.observation_type` gains `'survey'`; the run's observation row
is the record (D-029 pattern), so ledger, map, photos (`media_links` on the
observation), review, export and sync carry it with no new plumbing. Site
coordinates are the intended spot; the observation holds where the phone
stood. Percent cover, stems per acre, mean pole reading, richness are
derived from `values_json` on read (rule 6), never stored.

`fields_json` is a list of closed-type fields: `int`, `real`, `class`
(named ordinal scale: `daubenmire6`, `braun_blanquet`, `severity4`,
`wind4`), `choice`, `bool`, `text`, `taxa`, `count_by_taxon` (rows of
`{taxon_id, count, by}`), `photo`, `group` (repeat N, fixed sample names,
or open). Custom protocols reuse it with `method_key='custom'`.

## Templates (lib/protocols/templates.dart)

Starters: **Cover check** (Daubenmire frames at 5 m along a 25 m tape),
**Brush count** (1/100-acre circle, stems by species × size class),
**Cover pole** (Robel VOR from four directions), **Ten-minute listen**
(point count, 25/50 m bands, on-screen clock). More methods: **Pin walk**
(line-point intercept with soil-surface codes and gaps), **Soil surface
look** (six IIRH indicators + litter depth), **Spotlight drive** (TPWD
route count; acres sampled, acres/deer, does/buck, fawns/doe).

Not templates: survival (D-018), cameras/recorders (§4.12), canopy as its
own method (a field on Brush count), stream profiles (v2).

## Export

`data/protocol_runs_long.csv` — one row per site × run × sample × field;
class answers carry both class and midpoint; WGS84; ISO dates plus an
`observed_date` column; taxon rows carry the USDA symbol. `data/
protocol_runs_wide.csv` — one row per run with computed indicators as
columns. `geo/protocol_sites.geojson`. `data/schema.ini` for ArcGIS type
sniffing. Share mode blanks coordinates as it does for records.

## UX

Grow › **Monitoring** (fourth sub-tab): due list, sites, "Start a method"
cards, "More methods…" row. A card explains the method in four lines and
ends with "Put the first stake on the map" → new-site sheet: where I stand
or move the pin, bearing (my heading) and length for a line, radius for a
plot, what is in the ground, "also a photo point." Site detail: facts,
"since last time" deltas, every visit with headline numbers, retire
("stop asking here"). Run screen: one sample per page, class chips with the
lay word and the academic class in fine print, last time's answer in ghost
text, NEXT dims until the frame's required chips are picked, FINISH on a
short run offers "keep it as a partial." The record detail shows a run
summary card for survey records.

Not yet built: site marks on the map layer and "Walk me there" navigation
(the photo-point readout is the pattern), custom-protocol builder UI (the
service supports it), evidence-packet monitoring page, desk views.

Sources: TPWD guidelines and Appendix A Census; NRCS CPS 528/314/391; NM
NRCS VOR protocol; Herrick et al. Monitoring Manual Vol. I/II; Landscape
Toolbox; BLM AIM; Rangelands Gateway; IIRH v5; Matsuoka et al. 2014
Condor; R4DS tidy data; ArcGIS Pro XY import.
