import 'package:flutter_test/flutter_test.dart';

import 'smoke_cases.dart';

/// Host entry for the smoke suite: `flutter test test/smoke`. The same
/// cases run on a device from `integration_test/smoke_test.dart`.
void main() {
  // Asset-backed services (the state resolver, the bundled palette) read
  // through rootBundle, which wants a binding.
  TestWidgetsFlutterBinding.ensureInitialized();
  registerSmokeCases();
}
