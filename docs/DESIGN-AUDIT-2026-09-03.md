# Design audit — 2026-09-03

Five parallel reviewers over the whole app: visual tokens, map mark language,
mobile UX flows, desktop posture/parity, and the export plate. Trigger:
Austin's 2026-09-03 verdicts — record shapes missing, cluster badges too
small, the plate workspace "abysmal", and no map on the desk at all.

Deduped and ranked. Items marked **[done]** were fixed the same day.

---

## Fixed immediately

- **[done] Cluster badges too small** — addImage registers at density 1, so
  badges rendered ~36 device px, smaller than the dots they gather. Badge
  artwork resized (smallest ≈60 px) with count text to match
  (`map/cluster_badge.dart`).
- **[done] Record shape language** — plants and observations stay circles;
  infrastructure = ink square, maintenance = ochre square, problem = oxblood
  triangle, same silhouettes as the Features layer but in the record layer's
  paper stroke at record-dot weight. **Size + halo = layer, shape = class,
  color = domain.** (`map/map_markers.dart` `recordShapeMarker`,
  `map/map_screen.dart` split circle/symbol layers.)
- **[done] Silent capture discard** — the shutter step's CANCEL and system
  back now route through `_confirmDiscard`; a re-shot photo ("ANOTHER
  PHOTO" returns to step 0) can no longer vanish without a question
  (`screens/capture_screen.dart`).

---

## P1 — The big rocks (each is a real build; sequence with Austin)

### 1. Export plate redesign (Austin: "abysmal… it's just the map with a
legend and tables under it")

Target: layers + one Save menu on the left; an always-live composed LETTER
PAGE on the right — map on top, legend and tables below, exactly as it
prints. No DRAW button.

- Live preview: auto-render debounced on any layer change; kill the stale
  preview/save mismatch (`_document` currently mixes an old plate PNG with
  new layer metadata).
- Preview the composed page, not the bare map PNG — the legend/tables half
  is currently invisible until you open the saved PDF.
- SAVE PNG must export the composed page (today it saves a map with nothing
  under it — the format most likely to be emailed fails the whole spec).
- Session tile cache `(z,x,y)→image` so redraws are near-instant (today
  every redraw refetches every tile; this is what makes the blind loop
  painful).
- Tables must name what's on the map: add a features table (name · class)
  and a records summary (type/species · count). Feature names are loaded
  then thrown away today.
- De-duplicate legend vs zone table (swatch into the zone rows; legend for
  marks only). DOCX and PDF currently even order the legend differently.
- One mark module shared by phone map, plate, and HTML so the plate looks
  like *his* map (see P1-3). Drop the paper wash over imagery.
- Status line: say nothing on success; only warnings ("N tiles unavailable")
  and save confirmations. Clear prepared-for/notes on property switch.

### 2. A map on the desk (Austin: "critically important")

The desk has no interactive map. Two paths, decision needed:
- **(a) Native pan/zoom tile map** on the existing machinery (web_mercator +
  tile fetch + mark drawing already written for the plate; MapPlate was
  designed to double as the desk map). Offline-capable, no new deps,
  read-only first: pan/zoom, marks, click → open record in inspector.
  Then click-to-move-pin (desk pin correction is a natural "refine" task).
- **(b) WebView embedding the MapLibre-JS page** we already generate for
  HTML export. Full slippy-map feel sooner, but adds a webview dependency,
  needs a JS↔Dart bridge for clicks, and is online-only unless we proxy
  tiles.

Recommendation: (a) — it matches D-024's own design note and keeps
offline-first. Photo use case (nice-camera photos → species record): ADD
PHOTOS already works in the desk inspector; the map makes the record
findable spatially.

### 3. One mark table for the whole app

Records speak three color dialects today (phone map hex table, PlateInk,
tokens.recordTypeColor) — same record, three colors. Consolidate:
- One `recordInk` table (agent's proposal below) consumed by map_screen,
  map_plate, map_html, and the list diamonds.
- Fix red overload: one oxblood for "problem" everywhere; boundary gets its
  identity via weight/darker maroon; polygon editor gets a neutral working
  color.
- No two record types share a hex (today vine==phenology, forb==sign,
  water==weather, maintenance==infrastructure==tracks line).
- `general` falls back to warm gray, not plant green.
- Zones: persist a stable `colorHex` per zone, drawn identically on screen
  and plate (today: one anonymous green on screen, ten rotating colors in
  print, and the rotation collides with boundary/feature colors).
- HTML export: draw feature shapes (today every feature is a plain circle —
  the shape language dies in the shareable artifact) and a per-type records
  legend.

Proposed mapping (from the map-language reviewer):

| type | shape | color |
|---|---|---|
| plant | circle | growth-form greens; sage #4E6B4A unnamed |
| phenology | circle | moss #7A8C3B |
| wildlife | circle | ochre #A8791F |
| sign | circle | ochre-light #C29A4B |
| water | circle | river #2F5D8A |
| soil | circle | umber #7A5C3B |
| general | circle | warm gray #6B655C |
| infrastructure | square | ink #1B1813 |
| maintenance | square | ochre #A8791F |
| problem | triangle | oxblood #8B2E22 |

### 4. Desk Review is incomplete

- Tab switch destroys all workspace state (plate composition, review
  selection). Fix: IndexedStack like the phone shell.
- Review queue shows only observations; zone/planting/check-in edits never
  appear and the PENDING count under-reports. Drive it from
  `ReviewService.pending()` with typed rows.
- No species surface on the desk (D-024 names species refinement as desk
  work); no plantings/photo-points/features views; survival rows are dead
  ends. Embed the shared screens like RecordDetailScreen.
- Ledger filters (zone/type/species/date + text search) in the queue header.
- Keyboard: ↑/↓ walk queue, A/R approve/remove, ←/→ photo carousel.

---

## P2 — Mobile UX batch (small, high-frequency)

1. Map chrome buttons (~30 dp) → ≥48 dp hit areas (glove targets; spec says
   56). `map_tab.dart` control stack.
2. Phone photo tap → full-size viewer (today desk-only); drop the bare
   long-press-to-delete (viewer already has a visible delete).
3. Ledger filter chips → `Metrics.touchMin` height (map_tab's chip is
   already 56; ledger's is ~38 — extract one `ToggleChip` into press.dart).
4. Grow lists: bottom padding 140 so the last row clears the stacked FABs
   (plantings/propagation/features; photo points already pads).
5. Plant check-in: visible trailing button per row (today long-press-only —
   the M2 return-visit loop is behind an undiscoverable gesture).
6. Features screen: row tap → detail/history (today it opens the log-
   condition dialog); flag the centroid fallback at save time ("flagged,
   never faked" applies here too); add move-pin.
7. Missing-row screens: "gone from the ledger" instead of spinner-forever
   (record detail, dossier, planting detail, batch detail).
8. Empty states in house voice for plantings/propagation/features.
9. backup_screen: delete "Drive upload is coming" (it shipped, D-021);
   reskin from stock Material; on desk it still says "this phone"
   everywhere and shares via mobile sheet (desk → save dialog).
10. Voice note one tap from the photo (mic beside + NOTES in step-1 footer).
11. One-time hint chip for long-press-to-place-a-record.
12. Identify sheet: offline error says the move ("your photo is saved — ask
    again from the record when you have signal").
13. Standardize create/log forms on the press bottom-sheet grammar (today:
    three competing idioms).
14. Filter pills in the layers sheet get their color/shape swatch — the
    filter sheet becomes the in-app legend for free.
15. Capture ✕ discard button 46→56 px; Grow sub-tab row 44→56.

## P3 — Polish / consistency

- `features_screen._conditionColor` and programs status colors use stock
  Material greens/oranges → route through tokens (`conditionColor()`, new
  `programStatusColor()`).
- Ghost-capture alignment states and photo-points "due" chip → sage/ochre.
- PlateInk paper (#F7F6F2) leaks into app UI (identify veil, carousel
  arrows, badge text) → Press.paperRaised.
- Marker rasters read skin colors at draw time (quiet skin currently gets
  press-colored map furniture); do this when landing P1-3.
- CANCEL vs Cancel split in dialogs → `skin.label()`; wrap snackbar strings.
- InkCard adoption (33 hand-rolled bordered containers, wandering padding).
- Desk shell hardcodes press-ink shadows/dividers under quiet.
- Windows/Linux runners: mirror the 900×600 minimum; let Export preview
  exceed the 1400 px content cap.
- GPS accuracy ring under the reticle (data-driven radius from `acc` —
  plumbed but never drawn).
- Selection halo on tapped map marks; type swatches in records-here/feature
  sheet rows.
- Status bar "Write queue empty | Sync off" is hardcoded → derive from
  oplog or reword as static fact.
- The "design README §3.x" cited throughout code doesn't exist in the repo
  (app/README.md is stock Flutter). Write `docs/DESIGN.md` as the mark
  language + screen-spec home; move this audit's tables into it.

## Held up clean (all five reviewers)

Identify consent flow and empty states; review feed's pending-visible copy;
ghost capture + photo-point history; LAN/Drive backup screens' honesty;
desk intake posture (D-024 exactly); receive/pairing QR panel; the shared
edit sheet; feature silhouettes identical phone↔plate; cluster grammar
shared across surfaces; reticle design; records-off-by-default exports with
privacy copy at the switch (hard rule 3); house voice in error copy
("Save failed — nothing written"); token discipline overall (D-023's getter
seam holds; semantic color maps centralized).
