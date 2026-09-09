import '../services/secret_store.dart';

/// Which LLM the user has pointed the app at. Their key, their account,
/// their choice of provider (spec §5: bring your own key).
enum LlmProvider { anthropic, openai, custom }

extension LlmProviderLabel on LlmProvider {
  String get label => switch (this) {
    LlmProvider.anthropic => 'Anthropic (Claude)',
    LlmProvider.openai => 'OpenAI',
    LlmProvider.custom => 'Custom (OpenAI-compatible)',
  };

  String get storageValue => name;

  /// A sensible current model for each, editable by the user.
  String get defaultModel => switch (this) {
    LlmProvider.anthropic => 'claude-opus-5',
    LlmProvider.openai => 'gpt-5',
    LlmProvider.custom => '',
  };

  String get defaultBaseUrl => switch (this) {
    LlmProvider.anthropic => 'https://api.anthropic.com',
    LlmProvider.openai => 'https://api.openai.com',
    LlmProvider.custom => '',
  };
}

/// Identification credentials, in the platform keystore (or, where the
/// keystore refuses this build, the sandboxed secrets file — see
/// [SecretStore]) — never in the database, never in an export, never in a
/// PLAIN backup. They do ride in
/// the sealed body of an encrypted backup (see [exportAll]), which is how a
/// paired computer ends up with the same keys as the phone: only someone
/// holding the passphrase or recovery phrase can get them out.
class IdKeys {
  IdKeys({SecretStore? store}) : _storage = store ?? SecretStore();

  final SecretStore _storage;

  static const _plantNet = 'plantnet_api_key';
  static const _llmKey = 'llm_api_key';
  static const _llmProvider = 'llm_provider';
  static const _llmModel = 'llm_model';
  static const _llmBaseUrl = 'llm_base_url';

  Future<String?> _read(String k) async {
    try {
      return await _storage.read(k);
    } catch (_) {
      return null; // no keystore on this platform
    }
  }

  Future<void> _write(String k, String? v) async {
    try {
      if (v == null || v.isEmpty) {
        await _storage.delete(k);
      } else {
        await _storage.write(k, v);
      }
    } catch (_) {}
  }

  Future<String?> get plantNetKey => _read(_plantNet);
  Future<void> setPlantNetKey(String? v) => _write(_plantNet, v?.trim());

  Future<String?> get llmKey => _read(_llmKey);
  Future<void> setLlmKey(String? v) => _write(_llmKey, v?.trim());

  Future<LlmProvider> get llmProvider async {
    final raw = await _read(_llmProvider);
    return LlmProvider.values.firstWhere(
      (p) => p.name == raw,
      orElse: () => LlmProvider.anthropic,
    );
  }

  Future<void> setLlmProvider(LlmProvider p) =>
      _write(_llmProvider, p.storageValue);

  Future<String> get llmModel async {
    final raw = await _read(_llmModel);
    if (raw != null && raw.isNotEmpty) return raw;
    return (await llmProvider).defaultModel;
  }

  Future<void> setLlmModel(String? v) => _write(_llmModel, v?.trim());

  Future<String> get llmBaseUrl async {
    final raw = await _read(_llmBaseUrl);
    if (raw != null && raw.isNotEmpty) return raw;
    return (await llmProvider).defaultBaseUrl;
  }

  Future<void> setLlmBaseUrl(String? v) => _write(_llmBaseUrl, v?.trim());

  Future<bool> get hasPlantNet async =>
      (await plantNetKey)?.isNotEmpty ?? false;
  Future<bool> get hasLlm async => (await llmKey)?.isNotEmpty ?? false;

  static const _all = [
    _plantNet,
    _llmKey,
    _llmProvider,
    _llmModel,
    _llmBaseUrl,
  ];

  /// Every stored key/setting, for the sealed body of an ENCRYPTED backup
  /// (the engine never asks for a plain one). A paired computer restoring
  /// with the passphrase gets the same Pl@ntNet and AI account as the phone.
  Future<Map<String, String>> exportAll() async {
    final out = <String, String>{};
    for (final k in _all) {
      final v = await _read(k);
      if (v != null && v.isNotEmpty) out[k] = v;
    }
    return out;
  }

  /// Default provider for the backup engine: this device's keystore.
  static Future<Map<String, String>> exportForBackup() => IdKeys().exportAll();

  /// Store keys that arrived in a restored backup. Only known names are
  /// accepted; an empty value clears the key.
  Future<void> importAll(Map<String, String> secrets) async {
    for (final k in _all) {
      if (secrets.containsKey(k)) await _write(k, secrets[k]);
    }
  }
}
