/// The repository layer (D-038 item 5): each repo takes the database, owns
/// its queries and its change streams, and hands screens typed rows. A
/// screen that needs a row asks a repo; it does not import drift.
library;

export 'media_repo.dart';
export 'observations_repo.dart';
export 'photo_points_repo.dart';
export 'properties_repo.dart';
export 'taxa_repo.dart';
export 'zones_repo.dart';
