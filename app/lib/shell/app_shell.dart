import 'dart:io';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

import '../backup/backup_service.dart';
import '../main.dart' show opLog;
import '../sync/sync_service.dart';
import '../db/database.dart';
import '../id/id_keys.dart';
import '../screens/capture_screen.dart';
import '../screens/identify_sheet.dart';
import '../screens/record_detail_screen.dart';
import '../services/app_prefs.dart';
import '../services/observation_ops.dart';
import '../services/record_filter.dart';
import '../widgets/new_place_dialog.dart';
import '../widgets/save_toast.dart';
import '../tabs/grow_tab.dart';
import '../tabs/ledger_tab.dart';
import '../tabs/map_tab.dart';
import '../tabs/settings_tab.dart';
import '../tabs/species_tab.dart';
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// Five-tab shell (design README §3): Map · Ledger · Grow · Species ·
/// Settings, diamond tab marks, capture FAB floating over the bar's right
/// side on every tab.
class AppShell extends StatefulWidget {
  const AppShell({
    super.key,
    required this.db,
    required this.prefs,
    required this.property,
    required this.onSwitchProperty,
  });

  final FieldNotesDb db;
  final AppPrefs prefs;
  final Property property;
  final ValueChanged<Property> onSwitchProperty;

  @override
  State<AppShell> createState() => _AppShellState();
}

class _AppShellState extends State<AppShell> with WidgetsBindingObserver {
  /// The active tab survives the shell being torn down and rebuilt — which
  /// happens on every skin swap (D-023: the root MaterialApp is re-keyed).
  /// Without this, changing the skin from Settings dumped you back on the
  /// Map. Process-lifetime only, deliberately: a fresh launch starts on the
  /// Map as always.
  static int _lastTab = 0;
  int _tab = _lastTab;

  /// The ledger's LOCATE hands the map a destination through this.
  final _mapFocus = ValueNotifier<LatLng?>(null);

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Registered BEFORE the tabs build, so this listener runs before the
    // map consumes the jump.
    recordFilter.addListener(_onFilterJump);
  }

  void _onFilterJump() {
    if (recordFilter.jumpPending && _tab != 0 && mounted) {
      setState(() => _tab = 0);
    }
  }

  @override
  void dispose() {
    recordFilter.removeListener(_onFilterJump);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Spec §11.7: automatic backup runs opportunistically — here, whenever
  /// the app comes back to the foreground. The service decides whether it's
  /// due; this just gives it the chance.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      BackupService(widget.db)
          .maybeRunAutomatic(widget.prefs)
          .catchError((_) => null);
      final log = opLog;
      if (log != null) {
        SyncService(
          widget.db,
          widget.prefs,
          log,
        ).maybeRunAutomatic().catchError((_) => null);
      }
    }
  }

  static const _tabs = ['Map', 'Ledger', 'Grow', 'Species', 'Settings'];

  Future<void> _openCapture({LatLng? placedAt}) async {
    final result = await Navigator.of(context).push<CaptureResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => CaptureScreen(
          db: widget.db,
          property: widget.property,
          placedLat: placedAt?.latitude,
          placedLng: placedAt?.longitude,
        ),
      ),
    );
    if (!mounted || result == null) return;
    // Land on the Ledger with the new row on top (README §5), then the
    // toast — the privacy promise restated at every write.
    setState(() => _tab = 1);
    final ms = result.elapsed.inMilliseconds;
    final speed = ms < 1000
        ? 'INSTANTLY'
        : 'IN ${(ms / 1000).toStringAsFixed(1)} S';
    // Identify belongs at the moment of saving (audit U1) — but only when
    // the record actually has a photo and a key is on file; a dead-end
    // button teaches people to ignore the toast.
    final identifyReady = await _identifyPhotosFor(result.observationId);
    if (!mounted) return;
    SaveToast.show(
      context,
      title: 'OBSERVATION WRITTEN $speed',
      detail: 'SAVED ON THIS PHONE · NOTHING HAS LEFT IT',
      actionLabel: identifyReady.isEmpty ? null : 'IDENTIFY',
      onAction: identifyReady.isEmpty
          ? null
          : () => _identifyJustSaved(result.observationId, identifyReady),
      // Undo erases the record outright — row, photo, links, context — so
      // nothing of it reaches the next backup or export.
      onUndo: () => eraseObservation(widget.db, result.observationId),
    );
  }

  /// The record's photos, in link order, if identification could actually
  /// run: at least one photo on disk and a key on file. Empty means the
  /// toast doesn't offer the action.
  Future<List<File>> _identifyPhotosFor(String observationId) async {
    try {
      final keys = IdKeys();
      if (!(await keys.hasPlantNet) && !(await keys.hasLlm)) return const [];
      return await observationPhotoFiles(widget.db, observationId);
    } catch (e) {
      // Best-effort gate: a failure only hides the button, but say so.
      debugPrint('save-toast identify gate failed: $e');
      return const [];
    }
  }

  Future<void> _identifyJustSaved(
    String observationId,
    List<File> photos,
  ) async {
    final obs = await (widget.db.select(
      widget.db.observations,
    )..where((o) => o.id.equals(observationId))).getSingleOrNull();
    if (obs == null || !mounted) return;
    await showIdentifySheet(
      context,
      db: widget.db,
      observation: obs,
      property: widget.property,
      photos: photos,
    );
  }

  Future<void> _switchProperty() async {
    final properties =
        await (widget.db.select(widget.db.properties)
              ..where((x) => x.deletedAt.isNull())
              ..orderBy([(x) => OrderingTerm.asc(x.name)]))
            .get();
    if (!mounted) return;
    final picked = await showModalBottomSheet<Object>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(13, 14, 13, 6),
              child: MonoLabel('Places', size: 9, spacing: 2),
            ),
            for (final property in properties)
              ListTile(
                minTileHeight: 56,
                leading: Diamond(
                  size: 13,
                  color: property.id == widget.property.id
                      ? Press.oxblood
                      : Press.inkSoft,
                  filled: property.id == widget.property.id,
                ),
                title: Text(
                  property.name.toUpperCase(),
                  style: TextStyle(
                    fontFamily: Type.slab,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                subtitle: MonoLabel(
                  property.landTenure.replaceAll('_', ' '),
                  size: 8.5,
                  opacity: 0.7,
                ),
                onTap: () => Navigator.pop(context, property),
                // Rename / remove (Austin, 2026-08-31: "you cannot delete,
                // edit"). Kept off the main tap path — switching stays the
                // one-tap action.
                trailing: IconButton(
                  tooltip: 'Edit place',
                  icon: Icon(
                    Icons.edit_outlined,
                    size: 20,
                    color: Press.inkSoft,
                  ),
                  onPressed: () => Navigator.pop(context, _EditPlace(property)),
                ),
              ),
            // D-003: more than one place from day one — owned, leased,
            // public land, a collection site. This is the only way in after
            // first run.
            ListTile(
              minTileHeight: 56,
              leading: Icon(Icons.add, size: 18, color: Press.ink),
              title: Text(
                'ADD A PLACE',
                style: TextStyle(
                  fontFamily: Type.mono,
                  fontSize: 11,
                  letterSpacing: 1.6,
                  color: Press.ink,
                ),
              ),
              onTap: () => Navigator.pop(context, _addPlace),
            ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    if (picked == _addPlace) {
      if (!mounted) return;
      final created = await showNewPlaceDialog(context, widget.db);
      if (created != null) widget.onSwitchProperty(created);
      return;
    }
    if (picked is _EditPlace) {
      if (!mounted) return;
      await _editPlace(picked.property);
      return;
    }
    if (picked is Property && picked.id != widget.property.id) {
      widget.onSwitchProperty(picked);
    }
  }

  /// Rename or soft-delete a place. Deleting keeps every record (soft
  /// delete, like everything else in the schema) and never orphans the UI:
  /// the last remaining place can't be removed, and removing the active one
  /// switches you to another first.
  Future<void> _editPlace(Property property) async {
    final controller = TextEditingController(text: property.name);
    final action = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('EDIT PLACE'),
        content: TextField(
          controller: controller,
          autofocus: true,
          textCapitalization: TextCapitalization.words,
          decoration: const InputDecoration(labelText: 'Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, 'delete'),
            child: Text('REMOVE…', style: TextStyle(color: Press.oxblood)),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('CANCEL'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, 'save'),
            child: const Text('SAVE'),
          ),
        ],
      ),
    );
    if (action == 'save') {
      final name = controller.text.trim();
      if (name.isEmpty || name == property.name) return;
      await (widget.db.update(
        widget.db.properties,
      )..where((x) => x.id.equals(property.id))).write(
        PropertiesCompanion(name: Value(name), updatedAt: Value(nowUtcIso())),
      );
      if (property.id == widget.property.id && mounted) {
        final fresh = await (widget.db.select(
          widget.db.properties,
        )..where((x) => x.id.equals(property.id))).getSingle();
        widget.onSwitchProperty(fresh);
      }
      return;
    }
    if (action != 'delete' || !mounted) return;

    final others =
        await (widget.db.select(widget.db.properties)
              ..where((x) => x.deletedAt.isNull())
              ..where((x) => x.id.equals(property.id).not()))
            .get();
    if (others.isEmpty) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'This is your only place — add another before '
            'removing it.',
          ),
        ),
      );
      return;
    }
    final obsCount =
        await (widget.db.selectOnly(widget.db.observations)
              ..addColumns([widget.db.observations.id.count()])
              ..where(
                widget.db.observations.propertyId.equals(property.id) &
                    widget.db.observations.deletedAt.isNull(),
              ))
            .map((r) => r.read(widget.db.observations.id.count()) ?? 0)
            .getSingle();
    if (!mounted) return;
    final sure = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('REMOVE THIS PLACE?'),
        content: Text(
          '"${property.name}" and its $obsCount record'
          '${obsCount == 1 ? '' : 's'} will be removed from your lists. '
          'Nothing is destroyed — it all stays in the database and in '
          'backups, and can be brought back later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('KEEP IT'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('REMOVE'),
          ),
        ],
      ),
    );
    if (sure != true) return;
    await (widget.db.update(
      widget.db.properties,
    )..where((x) => x.id.equals(property.id))).write(
      PropertiesCompanion(
        deletedAt: Value(nowUtcIso()),
        updatedAt: Value(nowUtcIso()),
      ),
    );
    if (property.id == widget.property.id && mounted) {
      widget.onSwitchProperty(others.first);
    }
  }

  /// Sentinel row value for "add a place" in the switcher sheet.
  static const _addPlace = '__add_place__';

  @override
  Widget build(BuildContext context) {
    final body = IndexedStack(
      index: _tab,
      children: [
        MapTab(
          db: widget.db,
          property: widget.property,
          prefs: widget.prefs,
          active: _tab == 0,
          focus: _mapFocus,
          onPropertyCardTap: _switchProperty,
          onDropRecord: (latLng) => _openCapture(placedAt: latLng),
          onRecordTap: (id) => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => RecordDetailScreen(db: widget.db, obsId: id),
            ),
          ),
        ),
        LedgerTab(
          db: widget.db,
          property: widget.property,
          prefs: widget.prefs,
          // LOCATE on a ledger row: hop to the map and fly there.
          onLocate: (obs) {
            _mapFocus.value = LatLng(obs.lat, obs.lng);
            setState(() => _tab = 0);
          },
        ),
        GrowTab(db: widget.db, property: widget.property),
        SpeciesTab(db: widget.db, property: widget.property),
        SettingsTab(
          db: widget.db,
          property: widget.property,
          prefs: widget.prefs,
        ),
      ],
    );

    return Scaffold(
      body: Stack(
        children: [
          Positioned.fill(child: body),
          // Capture FAB: offset above the tab bar, right gutter 13.
          Positioned(
            right: Metrics.gutter,
            bottom: 68 - 36 + MediaQuery.of(context).padding.bottom + 36,
            child: CaptureFab(onPressed: _openCapture),
          ),
        ],
      ),
      bottomNavigationBar: _TabBar(
        tabs: _tabs,
        current: _tab,
        onTap: (i) => setState(() => _tab = _lastTab = i),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.tabs,
    required this.current,
    required this.onTap,
  });

  final List<String> tabs;
  final int current;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: Press.paperEdge,
        border: Border(
          top: BorderSide(
            color: Press.borderInk,
            width: Metrics.borderStructural,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          // Taller bar, bigger type (Austin, 2026-08-31: "bottom menu too
          // small / illegible on map"). This is the most-hit control in the
          // app and it's hit in sunlight; it gets legibility before style.
          height: 74,
          child: Row(
            children: [
              for (var i = 0; i < tabs.length; i++)
                Expanded(
                  child: Semantics(
                    label: '${tabs[i]} tab',
                    selected: i == current,
                    button: true,
                    child: InkWell(
                      onTap: () => onTap(i),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Diamond(
                            size: 13,
                            color: i == current ? Press.oxblood : Press.inkSoft,
                            filled: i == current,
                          ),
                          const SizedBox(height: 6),
                          Text(
                            skin.label(tabs[i]),
                            style: TextStyle(
                              fontFamily: Type.mono,
                              fontSize: skin.upperLabels ? 11 : 12.5,
                              fontWeight: i == current
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                              letterSpacing: skin.upperLabels ? 1.1 : 0.2,
                              color: i == current
                                  ? Press.ink
                                  : Press.inkSoft.withValues(alpha: 0.75),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Switcher-sheet result meaning "edit this one", distinct from picking it.
class _EditPlace {
  const _EditPlace(this.property);
  final Property property;
}
