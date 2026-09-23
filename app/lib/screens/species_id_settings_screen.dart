import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import '../id/id_keys.dart';
import '../id/plantnet_client.dart' show PlantNetClient, HttpClientHolder;
import '../theme/tokens.dart';
import '../widgets/press.dart';

/// Species ID setup (spec §5). Both layers are bring-your-own-key: the
/// user's account, the user's bill, the user's choice of provider. The
/// screen's job is to say plainly what each one is, what it costs, what
/// leaves the phone, and exactly how to get a key.
class SpeciesIdSettingsScreen extends StatefulWidget {
  const SpeciesIdSettingsScreen({super.key});

  @override
  State<SpeciesIdSettingsScreen> createState() =>
      _SpeciesIdSettingsScreenState();
}

class _SpeciesIdSettingsScreenState extends State<SpeciesIdSettingsScreen>
    with WidgetsBindingObserver {
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _catchKeyFromClipboard();
  }

  final _keys = IdKeys();
  final _http = HttpClientHolder();
  final _plantNetController = TextEditingController();
  final _llmKeyController = TextEditingController();
  final _modelController = TextEditingController();
  final _baseUrlController = TextEditingController();
  LlmProvider _provider = LlmProvider.anthropic;
  bool _hasPlantNet = false;
  bool _hasLlm = false;
  bool _loaded = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _http.close();
    _plantNetController.dispose();
    _llmKeyController.dispose();
    _modelController.dispose();
    _baseUrlController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final provider = await _keys.llmProvider;
    final model = await _keys.llmModel;
    final baseUrl = await _keys.llmBaseUrl;
    final hasPlantNet = await _keys.hasPlantNet;
    final hasLlm = await _keys.hasLlm;
    if (!mounted) return;
    setState(() {
      _provider = provider;
      _modelController.text = model;
      _baseUrlController.text = baseUrl;
      _hasPlantNet = hasPlantNet;
      _hasLlm = hasLlm;
      _loaded = true;
    });
  }

  /// One tap out to Pl@ntNet — where a Google account is enough to sign in
  /// — and on the way back the key is already in the box.
  Future<void> _openPlantNet() async {
    setState(() => _watchingClipboard = true);
    try {
      await launchUrl(
        Uri.parse('https://my.plantnet.org/account/settings'),
        mode: LaunchMode.externalApplication,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('COULD NOT OPEN THE BROWSER · GO TO MY.PLANTNET.ORG'),
          ),
        );
      }
    }
  }

  /// Coming back from the browser: if the clipboard now holds something
  /// key-shaped, put it in the field so there is nothing left to do but
  /// tap save.
  Future<void> _catchKeyFromClipboard() async {
    if (!_watchingClipboard) return;
    _watchingClipboard = false;
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      final text = data?.text?.trim();
      if (text == null || text.isEmpty) return;
      // Pl@ntNet keys are a single opaque token — no spaces, no punctuation
      // beyond the odd dash, and long enough not to be a stray word.
      final looksLikeKey =
          text.length >= 16 &&
          text.length <= 128 &&
          !text.contains(RegExp(r'[\s@/]'));
      if (!looksLikeKey || !mounted) return;
      setState(() => _plantNetController.text = text);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('KEY PASTED FROM CLIPBOARD · CHECKING IT')),
      );
      await _savePlantNet(validateFirst: true);
    } catch (_) {}
  }

  bool _watchingClipboard = false;
  bool _checking = false;

  Future<void> _savePlantNet({bool validateFirst = true}) async {
    final key = _plantNetController.text.trim();
    if (key.isEmpty) return;
    if (validateFirst) {
      setState(() => _checking = true);
      final ok = await _validate(key);
      if (!mounted) return;
      setState(() => _checking = false);
      if (!ok) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('THAT KEY WAS REFUSED · CHECK YOU COPIED ALL OF IT'),
          ),
        );
        return;
      }
    }
    await _keys.setPlantNetKey(key);
    _plantNetController.clear();
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('PL@NTNET KEY SAVED AND WORKING')));
    }
  }

  /// Ask Pl@ntNet whether the key is real, without spending an
  /// identification: a deliberately empty request answers 400 for a good key
  /// and 401/403 for a bad one.
  Future<bool> _validate(String key) async {
    try {
      final res = await _probe(key);
      return res != 401 && res != 403;
    } catch (_) {
      // Offline: accept it rather than block on a network we don't have.
      return true;
    }
  }

  Future<int> _probe(String key) async {
    final uri = Uri.https(PlantNetClient.host, '/v2/identify/k-world-flora', {
      'api-key': key,
      'nb-results': '1',
    });
    final res = await _http.post(uri).timeout(Duration(seconds: 15));
    return res.statusCode;
  }

  Future<void> _saveLlm() async {
    await _keys.setLlmProvider(_provider);
    if (_llmKeyController.text.trim().isNotEmpty) {
      await _keys.setLlmKey(_llmKeyController.text);
    }
    await _keys.setLlmModel(_modelController.text);
    await _keys.setLlmBaseUrl(_baseUrlController.text);
    _llmKeyController.clear();
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('SAVED')));
    }
  }

  Widget _step(int n, String text) => Padding(
    padding: EdgeInsets.only(bottom: 6),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(width: 22, child: MonoLabel('$n.', size: 10, spacing: 1.2)),
        Expanded(
          child: Text(
            text,
            style: TextStyle(fontFamily: Type.serif, fontSize: 15, height: 1.4),
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: Text('Species ID')),
      body: ListView(
        padding: EdgeInsets.all(Metrics.gutter),
        children: [
          Text(
            'The app never names a plant for you. It can offer suggestions, '
            'with its reasons, and you decide. Nothing is sent anywhere until '
            'you ask for an identification on a specific photo.',
            style: TextStyle(
              fontFamily: Type.serif,
              fontSize: 15.5,
              height: 1.45,
            ),
          ),
          SizedBox(height: 22),

          // ── Pl@ntNet ────────────────────────────────────────────────
          MonoLabel('Pl@ntNet · photo identification', size: 9, spacing: 1.8),
          SizedBox(height: 6),
          Container(
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Press.paperRaised,
              border: Border.all(color: Press.borderInk, width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Diamond(
                      size: 11,
                      color: _hasPlantNet ? Press.sage : Press.inkSoft,
                      filled: _hasPlantNet,
                    ),
                    SizedBox(width: 8),
                    MonoLabel(
                      _hasPlantNet ? 'Key saved' : 'No key yet',
                      size: 10,
                      spacing: 1.4,
                    ),
                    Spacer(),
                    if (_hasPlantNet)
                      TextButton(
                        onPressed: () async {
                          await _keys.setPlantNetKey(null);
                          _load();
                        },
                        child: Text('REMOVE'),
                      ),
                  ],
                ),
                SizedBox(height: 10),
                Text(
                  'Pl@ntNet is a non-profit run by French research '
                  'institutes. It identifies from the photograph alone.',
                  style: TextStyle(
                    fontFamily: Type.serif,
                    fontSize: 15,
                    height: 1.45,
                  ),
                ),
                SizedBox(height: 12),
                MonoLabel('Getting a key', size: 9, spacing: 1.6),
                SizedBox(height: 6),
                _step(
                  1,
                  'Tap below. Pl@ntNet opens — sign in with Google, or make '
                  'an account.',
                ),
                _step(2, 'Copy the API key it shows you.'),
                _step(
                  3,
                  'Come back here. It gets pasted and checked on its own.',
                ),
                SizedBox(height: 10),
                SizedBox(
                  height: 56,
                  child: FilledButton.icon(
                    icon: Icon(Icons.open_in_new),
                    label: Text('OPEN PL@NTNET'),
                    onPressed: _openPlantNet,
                  ),
                ),
                SizedBox(height: 10),
                Text(
                  'The free tier allows 500 identifications a day, which is '
                  'far more than a person walking their own land will use. '
                  'Commercial use beyond that needs a contract with them.',
                  style: TextStyle(
                    fontFamily: Type.serif,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
                SizedBox(height: 12),
                TextField(
                  controller: _plantNetController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: 'Pl@ntNet API key',
                    isDense: true,
                  ),
                ),
                SizedBox(height: 10),
                SizedBox(
                  height: 52,
                  child: OutlinedButton(
                    onPressed: _checking ? null : () => _savePlantNet(),
                    child: Text(_checking ? 'CHECKING…' : 'SAVE KEY'),
                  ),
                ),
              ],
            ),
          ),
          SizedBox(height: 24),

          // ── LLM re-rank ─────────────────────────────────────────────
          MonoLabel(
            'Second opinion · your own AI account',
            size: 9,
            spacing: 1.8,
          ),
          SizedBox(height: 6),
          Container(
            padding: EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Press.paperRaised,
              border: Border.all(color: Press.borderInk, width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Diamond(
                      size: 11,
                      color: _hasLlm ? Press.sage : Press.inkSoft,
                      filled: _hasLlm,
                    ),
                    SizedBox(width: 8),
                    MonoLabel(
                      _hasLlm ? 'Key saved' : 'No key yet',
                      size: 10,
                      spacing: 1.4,
                    ),
                    Spacer(),
                    if (_hasLlm)
                      TextButton(
                        onPressed: () async {
                          await _keys.setLlmKey(null);
                          _load();
                        },
                        child: Text('REMOVE'),
                      ),
                  ],
                ),
                SizedBox(height: 10),
                Text(
                  'This is the part that knows your ground. It sees the '
                  'photograph along with the county, the zone, the soil, the '
                  'month, and every species you have already recorded or '
                  'planted here — then ranks the candidates and tells you '
                  'why, so you can disagree with it.',
                  style: TextStyle(
                    fontFamily: Type.serif,
                    fontSize: 15,
                    height: 1.45,
                  ),
                ),
                SizedBox(height: 12),
                MonoLabel('Getting a key', size: 9, spacing: 1.6),
                SizedBox(height: 6),
                _step(
                  1,
                  'Anthropic: console.anthropic.com → API keys → Create key. '
                  'OpenAI: platform.openai.com → API keys.',
                ),
                _step(2, 'You pay that provider directly for what you use.'),
                _step(3, 'Paste the key below and pick the provider.'),
                SizedBox(height: 8),
                RailNote(
                  color: Press.oxblood,
                  body:
                      'A Claude Pro or ChatGPT Plus subscription is not API '
                      'access. API keys are billed separately, by usage.',
                ),
                SizedBox(height: 12),
                DropdownButtonFormField<LlmProvider>(
                  initialValue: _provider,
                  decoration: InputDecoration(
                    labelText: 'Provider',
                    isDense: true,
                  ),
                  items: [
                    for (final p in LlmProvider.values)
                      DropdownMenuItem(value: p, child: Text(p.label)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      _provider = v;
                      if (v != LlmProvider.custom) {
                        _modelController.text = v.defaultModel;
                        _baseUrlController.text = v.defaultBaseUrl;
                      }
                    });
                  },
                ),
                SizedBox(height: 10),
                TextField(
                  controller: _llmKeyController,
                  obscureText: true,
                  decoration: InputDecoration(
                    labelText: _hasLlm ? 'Replace API key' : 'API key',
                    isDense: true,
                  ),
                ),
                SizedBox(height: 10),
                TextField(
                  controller: _modelController,
                  decoration: InputDecoration(
                    labelText: 'Model',
                    isDense: true,
                  ),
                ),
                if (_provider == LlmProvider.custom) ...[
                  SizedBox(height: 10),
                  TextField(
                    controller: _baseUrlController,
                    decoration: InputDecoration(
                      labelText: 'Base URL (OpenAI-compatible)',
                      isDense: true,
                    ),
                  ),
                ],
                SizedBox(height: 12),
                SizedBox(
                  height: 52,
                  child: FilledButton(onPressed: _saveLlm, child: Text('SAVE')),
                ),
              ],
            ),
          ),
          SizedBox(height: 22),
          Text(
            'What leaves the phone when you ask for an identification: the '
            'one photograph, and a description of the place — county, zone, '
            'soil, month, and the species list for this property. Coordinates '
            'are rounded to about a kilometre. Nothing else, and nothing at '
            'all unless you ask.',
            style: TextStyle(
              fontFamily: Type.serif,
              fontSize: 14,
              height: 1.45,
            ),
          ),
          SizedBox(height: 8),
          MonoLabel(
            'Keys are held in this device\'s keystore — never in the '
            'database or an export. They travel to a paired computer only '
            'inside an encrypted backup, never a plain one.',
            size: 9,
            opacity: 0.7,
          ),
        ],
      ),
    );
  }
}
