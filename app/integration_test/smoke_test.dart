import 'package:integration_test/integration_test.dart';

import '../test/smoke/smoke_cases.dart';

/// On-device smoke suite. Same cases as the host run, now with the real
/// sqlite, filesystem and image codecs of the phone:
///
///   flutter test integration_test -d emulator-5554
///
/// Everything is written under the test app's own temp directory via a
/// replaced path provider; the production store is never opened. Run it
/// on the `fieldnotes` emulator, not on a phone that holds real records:
/// `flutter test integration_test` installs this build over whatever
/// carries the same package id.
void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  registerSmokeCases();
}
