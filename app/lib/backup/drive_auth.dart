import 'package:google_sign_in/google_sign_in.dart';

import '../services/desk.dart';
import 'drive_desktop_auth.dart';
import 'drive_target.dart';

/// Google sign-in, kept to the smallest surface that gets a Drive token.
///
/// Two deliberate choices, both about what this is *not*:
///
///  * The only scope requested is `drive.appdata`. Signing in does not create
///    an account with us, does not sync anything, and gives Google no view of
///    the journal — the app folder holds sealed blobs and Google holds no key.
///  * Nothing here runs unless the user taps Connect on the Backup screen.
///    The app never signs in on launch and never asks in the background.
///
/// The `serverClientId` is the **Web** OAuth client, which is how Google's
/// Android libraries are built: the Android client (matched by package name
/// and signing fingerprint) proves the request came from this app, and the
/// Web client is the identity string it presents. Both live in the same
/// Cloud project; see `docs/GOOGLE-DRIVE-SETUP.md`.
class DriveAuth {
  DriveAuth._();
  static final instance = DriveAuth._();

  /// Web client ID for the `field-notes-506920` Cloud project.
  /// Not a secret: it names the app, it authorises nothing on its own.
  static const serverClientId =
      '447000916304-t5mglcl7s586up04oobapom5sqiukkoq.apps.googleusercontent.com';

  bool _initialised = false;

  /// On a computer there is no Google Sign-In SDK to lean on; the desk uses
  /// the installed-app flow instead (D-024).
  static bool get _isDesk => isDesk;

  Future<void> _init() async {
    if (_initialised) return;
    await GoogleSignIn.instance.initialize(serverClientId: serverClientId);
    _initialised = true;
  }

  /// True when this build can talk to Google at all. On a phone whose
  /// fingerprint isn't registered, or a platform with no client configured,
  /// we want the Backup screen to say so rather than throw at tap time.
  Future<bool> get isSupported async {
    if (_isDesk) return true;
    try {
      await _init();
      return GoogleSignIn.instance.supportsAuthenticate();
    } catch (_) {
      return false;
    }
  }

  /// The address of the account this session last obtained a token for, or
  /// null. Reads nothing from Google — see the note below.
  ///
  /// There is deliberately no "ask Google who is signed in" call here.
  /// `attemptLightweightAuthentication()` sounds silent and is not: on
  /// Android it goes through Credential Manager, which puts the account
  /// picker on screen when there is no existing grant. Calling it just to
  /// label the Backup screen made a Google sheet appear the instant the
  /// screen opened — before the user had touched Connect — which is exactly
  /// what this app promises not to do. The screen shows the remembered
  /// address instead, and Google is only ever contacted from [accessToken].
  String? get lastKnownEmail => _lastEmail;
  String? _lastEmail;

  /// The desk remembers the address in the keychain; prime the label
  /// without contacting Google.
  Future<void> primeDeskEmail() async {
    if (_isDesk) _lastEmail = await DriveDesktopAuth.instance.email;
  }

  /// Get a token for the Drive app folder.
  ///
  /// [interactive] false is the automatic-backup path: it will reuse an
  /// existing grant and return null rather than put a Google dialog in front
  /// of someone who is standing in a field. True is the Connect button.
  ///
  /// Returns null when the user declines or has not connected.
  Future<String?> accessToken({required bool interactive}) async {
    if (_isDesk) {
      final token = await DriveDesktopAuth.instance.accessToken(
        interactive: interactive,
      );
      _lastEmail = await DriveDesktopAuth.instance.email;
      return token;
    }
    await _init();
    final signIn = GoogleSignIn.instance;

    GoogleSignInAccount? account = await signIn
        .attemptLightweightAuthentication();
    if (account == null) {
      // Only past this line does a Google dialog become possible, and only
      // because the user asked for one.
      if (!interactive) return null;
      if (!signIn.supportsAuthenticate()) {
        throw const DriveException(
          'Google sign-in is not available on this device.',
        );
      }
      account = await signIn.authenticate(scopeHint: const [DriveTarget.scope]);
    }
    _lastEmail = account.email;

    final client = account.authorizationClient;
    var authz = await client.authorizationForScopes(const [DriveTarget.scope]);
    if (authz == null) {
      if (!interactive) return null;
      authz = await client.authorizeScopes(const [DriveTarget.scope]);
    }
    return authz.accessToken;
  }

  /// Disconnect: forgets the account here *and* revokes the grant at Google,
  /// so "Disconnect" means what the word means. Backups already in Drive stay
  /// where they are; the user can delete them from Drive's storage settings.
  Future<void> disconnect() async {
    if (_isDesk) {
      await DriveDesktopAuth.instance.disconnect();
      _lastEmail = null;
      return;
    }
    try {
      await _init();
      await GoogleSignIn.instance.disconnect();
      _lastEmail = null;
    } catch (_) {
      // Already gone, or offline — either way the local grant is dropped.
    }
  }
}
