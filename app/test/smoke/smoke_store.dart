import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:field_notes/db/database.dart';
import 'package:field_notes/db/seed.dart';
import 'package:field_notes/sync/oplog.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:sqlite3/sqlite3.dart' as sql;

/// An isolated Field Notes store for the smoke suite: its own documents
/// directory, its own database file, its own media tree. Nothing here
/// touches the production store — the path provider is replaced for the
/// process, so every `getApplicationDocumentsDirectory()` inside the app
/// lands under [root]. Works on the host under `flutter test` and on a
/// device under `flutter test integration_test`, which is the point.
class SmokeStore {
  SmokeStore._(this.root, this.db, this.propertyId, this.deviceId);

  /// The fake documents directory. The live database is
  /// `root/field_notes.sqlite`, media under `root/media/`, exactly as the
  /// app lays them out (main.dart, media_store.dart).
  final Directory root;
  FieldNotesDb db;
  final String propertyId;
  final String deviceId;

  File get dbFile => File(p.join(root.path, 'field_notes.sqlite'));

  /// A place on the Lampasas River with a centroid and one zone drawn
  /// around it, so a located capture has a zone to fall into.
  static const lat = 30.8830;
  static const lng = -98.5470;

  /// Open a fresh store under a new temp root. [label] names the directory.
  static Future<SmokeStore> open({String label = 'fn-smoke'}) async {
    final root = Directory.systemTemp.createTempSync('$label-');
    pointPathsAt(root);
    final db = await _openDb(File(p.join(root.path, 'field_notes.sqlite')));
    final opLog = await OpLog.install(
      db,
      identityFile: File(p.join(root.path, 'device_id.txt')),
    );
    await seedFeatureTypesIfEmpty(db);

    final now = nowUtcIso();
    final propId = newId();
    await db
        .into(db.properties)
        .insert(
          PropertiesCompanion.insert(
            id: propId,
            name: 'Smoke Test Place',
            county: const Value('Lampasas'),
            state: const Value('TX'),
            boundaryGeojson: Value(ring(lng, lat, 0.007, 0.006)),
            centroidLat: const Value(lat),
            centroidLng: const Value(lng),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    await db
        .into(db.zones)
        .insert(
          ZonesCompanion.insert(
            id: newId(),
            propertyId: propId,
            name: 'River bottom',
            zoneType: const Value('riparian'),
            geojson: ring(lng, lat, 0.003, 0.003),
            createdBy: 'local',
            createdAt: now,
            updatedAt: now,
          ),
        );
    return SmokeStore._(root, db, propId, opLog.deviceId);
  }

  /// Point the app's documents, support and temp directories at [root].
  static void pointPathsAt(Directory root) {
    PathProviderPlatform.instance = _IsolatedPathProvider(root.path);
  }

  static Future<FieldNotesDb> _openDb(File file) async {
    // Several FieldNotesDb instances live in one process here (store,
    // restore copy, migration fixture); drift's warning about that is for
    // apps, not suites.
    driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
    final db = FieldNotesDb.fromFile(file);
    await db.customSelect('SELECT 1').get(); // open + migrate now, not lazily
    return db;
  }

  /// Close the database and open the same file again — what a relaunch
  /// does. Anything that was only in memory is gone after this.
  Future<void> reopen() async {
    await db.close();
    db = await _openDb(dbFile);
    await OpLog.install(
      db,
      identityFile: File(p.join(root.path, 'device_id.txt')),
    );
  }

  /// Close and delete everything. Call from tearDown.
  Future<void> dispose() async {
    await db.close();
    if (root.existsSync()) root.deleteSync(recursive: true);
  }

  /// A GeoJSON polygon ring, as the desk-shell test draws them.
  static String ring(double lng, double lat, double w, double h) => jsonEncode({
    'type': 'Polygon',
    'coordinates': [
      [
        [lng - w, lat - h],
        [lng + w, lat - h],
        [lng + w, lat + h],
        [lng - w, lat + h],
        [lng - w, lat - h],
      ],
    ],
  });
}

class _IsolatedPathProvider extends PathProviderPlatform
    with MockPlatformInterfaceMixin {
  _IsolatedPathProvider(this.root);
  final String root;
  @override
  Future<String?> getApplicationDocumentsPath() async => root;
  @override
  Future<String?> getApplicationSupportPath() async => root;
  @override
  Future<String?> getTemporaryPath() async => root;
}

/// The row counts the invariant is stated in: a saved record is never lost
/// (observations, media, media_links stay) and never hidden (live).
typedef Counts = ({
  int observations,
  int live,
  int media,
  int mediaLinks,
  int envContexts,
});

Future<Counts> countsOf(FieldNotesDb db) async {
  Future<int> count(String sql) async =>
      (await db.customSelect(sql).getSingle()).data['n'] as int;
  return (
    observations: await count('SELECT COUNT(*) AS n FROM observations'),
    live: await count(
      'SELECT COUNT(*) AS n FROM observations WHERE deleted_at IS NULL',
    ),
    media: await count('SELECT COUNT(*) AS n FROM media'),
    mediaLinks: await count('SELECT COUNT(*) AS n FROM media_links'),
    envContexts: await count('SELECT COUNT(*) AS n FROM env_contexts'),
  );
}

/// The media files a store should have on disk for a media row: the
/// original and, for a photo, its working copy and thumbnail.
List<File> filesFor(MediaData m) => [
  if (m.localPath != null) File(m.localPath!),
  if (m.localPath != null && m.mediaType == 'photo')
    File(p.setExtension(p.withoutExtension(m.localPath!), '.work.jpg')),
  if (m.thumbPath != null) File(m.thumbPath!),
];

/// A small real JPEG — decodable, so the media store derives its working
/// copy and thumbnail the way it does for a camera frame.
Uint8List smallJpeg({int width = 96, int height = 64}) {
  final image = img.Image(width: width, height: height);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, (x * 255) ~/ width, (y * 255) ~/ height, 90);
    }
  }
  return Uint8List.fromList(img.encodeJpg(image, quality: 80));
}

/// Writes [bytes] to [path] and hands the file back.
File writeFile(String path, List<int> bytes) =>
    File(path)
      ..parent.createSync(recursive: true)
      ..writeAsBytesSync(bytes);

/// A stand-in voice recording at a temporary path, as the recorder leaves
/// one for the capture screen. Not real audio; the store keeps bytes.
File fakeVoiceNote(Directory dir) => writeFile(
  p.join(dir.path, 'voice-${newId()}.m4a'),
  List<int>.generate(4096, (i) => (i * 31) % 251),
);

/// A database at schema v9 — the oldest shape the migration tests cover
/// (see test/migration_v10_test.dart): the observations CHECK without
/// 'survey', no protocol tables, no map_imports, zones without import_id
/// or hidden. One property, one record. The ids are fixed so a caller can
/// look them up after the upgrade.
const v9PropertyId = 'p1';
const v9ObservationId = 'o1';

void buildV9Fixture(File file) {
  file.parent.createSync(recursive: true);
  final raw = sql.sqlite3.open(file.path);
  try {
    raw.execute('''
      CREATE TABLE properties (
        id TEXT PRIMARY KEY NOT NULL, name TEXT NOT NULL, description TEXT,
        county TEXT, state TEXT, country TEXT DEFAULT 'US', acreage REAL,
        land_tenure TEXT NOT NULL DEFAULT 'owned',
        boundary_geojson TEXT, centroid_lat REAL, centroid_lng REAL,
        default_share_mode TEXT NOT NULL DEFAULT 'fuzzed',
        fuzz_radius_m INTEGER DEFAULT 500,
        created_by TEXT NOT NULL, created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL, deleted_at TEXT)''');
    // Stubs for every table the FKs point at; enforcement is on at open.
    for (final t in [
      'zones',
      'features',
      'taxa',
      'env_contexts',
      'photo_points',
      'tracks',
    ]) {
      raw.execute('CREATE TABLE $t (id TEXT PRIMARY KEY NOT NULL)');
    }
    raw.execute('''
      CREATE TABLE observations (
        id TEXT PRIMARY KEY NOT NULL,
        property_id TEXT NOT NULL REFERENCES properties(id),
        zone_id TEXT, feature_id TEXT,
        observed_at TEXT NOT NULL, local_tz TEXT NOT NULL,
        lat REAL NOT NULL, lng REAL NOT NULL,
        gps_accuracy_m REAL, altitude_m REAL, heading_deg REAL,
        observation_type TEXT NOT NULL DEFAULT 'general' CHECK (observation_type IN
          ('general','plant','wildlife','problem','water','soil','phenology',
           'sign','weather','maintenance','infrastructure')),
        taxon_id TEXT, taxon_confidence TEXT, count_estimate INTEGER,
        phenology TEXT, is_suggestion INTEGER NOT NULL DEFAULT 0,
        accepted_at TEXT, accepted_by TEXT, notes TEXT, env_context_id TEXT,
        removal_status TEXT, removed_on TEXT,
        created_by TEXT NOT NULL, created_at TEXT NOT NULL,
        updated_at TEXT NOT NULL, deleted_at TEXT)''');
    raw.execute(
      'CREATE INDEX idx_obs_prop_time ON observations(property_id, observed_at DESC)',
    );
    raw.execute(
      'CREATE INDEX idx_obs_bbox ON observations(property_id, lat, lng)',
    );
    raw.execute('CREATE INDEX idx_obs_taxon ON observations(taxon_id)');
    raw.execute(
      "INSERT INTO properties VALUES ('$v9PropertyId','Old place',NULL,NULL,"
      "NULL,'US',NULL,'owned',NULL,NULL,NULL,'fuzzed',500,'local',"
      "'2026-01-01T00:00:00Z','2026-01-01T00:00:00Z',NULL)",
    );
    raw.execute(
      'INSERT INTO observations (id, property_id, observed_at, local_tz, lat, '
      'lng, observation_type, notes, removal_status, created_by, created_at, '
      "updated_at) VALUES ('$v9ObservationId','$v9PropertyId',"
      "'2026-01-02T00:00:00Z','CST',31.06,-98.05,'plant','an old record',"
      "'flagged','local','2026-01-02T00:00:00Z','2026-01-02T00:00:00Z')",
    );
    raw.execute('PRAGMA user_version = 9');
  } finally {
    raw.close();
  }
}
