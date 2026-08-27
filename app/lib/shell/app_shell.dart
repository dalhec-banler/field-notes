import 'package:drift/drift.dart' hide Column;
import 'package:flutter/material.dart';
import 'package:maplibre_gl/maplibre_gl.dart' show LatLng;

import '../backup/backup_service.dart';
import '../db/database.dart';
import '../screens/capture_screen.dart';
import '../screens/record_detail_screen.dart';
import '../services/app_prefs.dart';
import '../services/observation_ops.dart';
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
  int _tab = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
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
    final seconds = (result.elapsed.inMilliseconds / 1000).toStringAsFixed(1);
    SaveToast.show(
      context,
      title: 'OBSERVATION WRITTEN IN $seconds S',
      detail: 'SAVED ON THIS PHONE · NOTHING HAS LEFT IT',
      // Undo erases the record outright — row, photo, links, context — so
      // nothing of it reaches the next backup or export.
      onUndo: () => eraseObservation(widget.db, result.observationId),
    );
  }

  Future<void> _switchProperty() async {
    final properties = await (widget.db.select(widget.db.properties)
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
                  style: const TextStyle(
                    fontFamily: Type.slab,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                ),
                subtitle: MonoLabel(property.landTenure.replaceAll('_', ' '),
                    size: 8.5, opacity: 0.7),
                onTap: () => Navigator.pop(context, property),
              ),
            // D-003: more than one place from day one — owned, leased,
            // public land, a collection site. This is the only way in after
            // first run.
            ListTile(
              minTileHeight: 56,
              leading: const Icon(Icons.add, size: 18, color: Press.ink),
              title: const Text(
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
    if (picked is Property && picked.id != widget.property.id) {
      widget.onSwitchProperty(picked);
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
          onPropertyCardTap: _switchProperty,
          onDropRecord: (latLng) => _openCapture(placedAt: latLng),
          onRecordTap: (id) => Navigator.of(context).push(MaterialPageRoute(
              builder: (_) => RecordDetailScreen(db: widget.db, obsId: id))),
        ),
        LedgerTab(db: widget.db, property: widget.property,
            prefs: widget.prefs),
        GrowTab(db: widget.db, property: widget.property),
        SpeciesTab(db: widget.db, property: widget.property),
        SettingsTab(
            db: widget.db, property: widget.property, prefs: widget.prefs),
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
        onTap: (i) => setState(() => _tab = i),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar(
      {required this.tabs, required this.current, required this.onTap});

  final List<String> tabs;
  final int current;
  final ValueChanged<int> onTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: Press.paperEdge,
        border: Border(
            top: BorderSide(color: Press.ink, width: Metrics.borderStructural)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 68, // glove-mode height
          child: Row(
            children: [
              for (var i = 0; i < tabs.length; i++)
                Expanded(
                  child: InkWell(
                    onTap: () => onTap(i),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Diamond(
                          size: 12,
                          color: i == current ? Press.oxblood : Press.inkSoft,
                          filled: i == current,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          tabs[i].toUpperCase(),
                          style: TextStyle(
                            fontFamily: Type.mono,
                            fontSize: 8.5,
                            letterSpacing: 1.2,
                            color: i == current
                                ? Press.ink
                                : Press.inkSoft.withValues(alpha: 0.6),
                          ),
                        ),
                      ],
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
