# Desk UX/UI audit — 2026-09-05

Trigger: Austin, 2026-09-04 — "I can['t] zoom in on the map on the desktop
app, only panning works… do a full ux ui audit of the desktop app. make
sure everything works after that massive code review and revision."

Scope: everything under `lib/desktop/` plus the export renderers the desk
drives, read in full against the 2026-09-03 design audit and the
2026-09-04 external audit. Verification is a new widget-test suite
(`test/desk_shell_test.dart`) that boots the real `DesktopShell` on a
fixture journal, walks all seven workspaces, rules on a pending edit, and
writes golden photographs of every tab (`test/goldens/desk/`).

## Fixed in this pass

1. **Trackpad pinch zoom did nothing** (`desk_map_view.dart`). A Mac
   trackpad never sends `PointerScrollEvent` — two-finger scroll and pinch
   arrive as pan-zoom pointer events. The drag recognizer turned the
   scroll into a pan (why panning "worked"), and the pinch's scale went
   nowhere. Now `onPointerPanZoomUpdate` zooms by the change in cumulative
   scale, anchored on the fingers; wheel and double-click behave as before.
2. **Feature panel query storm** (`desk_map_view.dart`). The panel built
   its `Future.wait` inline, so every pan frame refired three queries and
   flashed the spinner. Memoized per feature id.
3. **One failed tile blanked forever** (`desk_map_view.dart`). A tile
   fetch that failed once was never retried for the session. Failures now
   carry a timestamp and retry after 15 s.
4. **HTML export ignored species mode** (`map_html.dart`,
   `export_workspace.dart`). A species-filtered plate previewed filtered
   but the saved HTML carried **every** record's coordinates. `MapHtml`
   now takes the same species selection the plate drew: only chosen
   species ship, in their plate colours, and the legend follows.
5. **HTML export corrupted non-ASCII text** (`export_workspace.dart`).
   Bytes were written from `String.codeUnits`; an em dash or an accented
   species name produced mojibake. Now UTF-8.
6. **Everything built at launch** (`desktop_shell.dart`). The
   `IndexedStack` constructed all seven workspaces on startup — the Export
   bench rendered pages and fetched imagery for a tab nobody had opened
   (also the external audit's rule-3 note). Workspaces now build on first
   visit and keep their state afterwards.
7. **Stale title-bar readouts** (`desktop_shell.dart`). DB size, media
   count and the places list loaded once; imports and ADD PHOTOS left them
   wrong. Now they follow the journal via a stream watch.
8. **Stale pending queue** (`desktop_shell.dart`). The Review workspace's
   pending set loaded once; it now watches `review_items`.
9. **Review keyboard flow** (design audit P1-4 leftover): ↑/↓ walk the
   queue, A approves, R removes.
10. **Desk export used the phone's share sheet** (`main.dart`, design
    audit P2-9). On desktop, "Export all data" now opens a save dialog.
11. **Version easter egg gave no answer on the desk**
    (`settings_workspace.dart`). The seventh tap now reveals Appearance
    immediately and says so.

12. **Record detail red-screened on layout — live regression** (`widgets/
    press.dart`, `screens/record_detail_screen.dart`). The 2026-09-04
    Condition header put `Kicker` beside a `Spacer()` in a `Row`; a Row
    hands its plain children unbounded width, and Kicker's internal
    `Expanded` is a hard layout crash there. Any record that renders the
    Condition section threw a cascade of layout exceptions. The phone
    hasn't seen it only because it still runs the 09-01 APK. Fixed twice
    over: the call site gives Kicker the bounded slot, and Kicker itself
    now uses a loose `Flexible` so the next unbounded drop-in can't crash.
13. **AudioPlayer constructed for every record** (`record_detail_screen.
    dart`). The audio engine spun up on record open whether or not a voice
    note exists (and broke the desk test host, which has no audio plugin).
    Now lazy — created on first play.

## Verified working (by the new suite and by reading)

- All seven workspaces open without exception on a real journal; goldens
  captured for each (see `test/goldens/desk/`).
- Review: pending pill shows, APPROVE rules and persists, PENDING filter
  narrows the queue.
- Desk map: species panel groups by label, opens the record panel;
  unlocated records are excluded from marks and framing (external audit
  finding 14's fix held).
- Export: records layer off by default with the privacy warning at the
  switch; page preview composes; property switch clears prepared-for/notes
  (finding 10's fix held); script-injection fix in HTML (finding 13) held.
- Intake posture (D-024), receive/QR panel, Drive banner logic
  (`drive_watch.dart`) read clean.

## Known-open (deliberate or deferred)

- Desk Review queue lists observations only; zone/planting edits still
  don't surface there (design audit P1-4, larger schema-driven build).
- Non-Point features aren't clickable on the desk map.
- Record marks in exported HTML are circles; the square/triangle shape
  language doesn't survive into the interactive artifact (P1-3 tail).
- Desk shell is press-styled under the quiet skin (P3, known).
- Imagery is default-on by explicit product choice; the external audit's
  rule-3 wording tension is Austin's call, not code.
- Grow's sub-tab bar (PLANTINGS · PROPAGATION · PHOTO PTS) stretches its
  three labels across the full 1360 px window — legible but unconsidered
  at desk width.
- A desk Ledger row opens the record as a full-window phone route instead
  of an inspector pane; the Map tab's record panel is the better idiom
  and the two should converge.
- The Export page preview doesn't compose under the widget-test harness
  (real-async image work); its goldens photograph the workspace, not the
  rendered sheet. The live desk renders it — verified 2026-09-01 against
  real tiles.
- On-device confirmations that need a human hand: trackpad pinch feel,
  save dialogs, LAN receive end-to-end.
