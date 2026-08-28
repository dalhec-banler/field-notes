import 'package:flutter/material.dart';

import '../id/id_keys.dart';
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

class _SpeciesIdSettingsScreenState extends State<SpeciesIdSettingsScreen> {
  final _keys = IdKeys();
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
    _load();
  }

  @override
  void dispose() {
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

  Future<void> _savePlantNet() async {
    await _keys.setPlantNetKey(_plantNetController.text);
    _plantNetController.clear();
    await _load();
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('PL@NTNET KEY SAVED')));
    }
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
          .showSnackBar(const SnackBar(content: Text('SAVED')));
    }
  }

  Widget _step(int n, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 22,
              child: MonoLabel('$n.', size: 10, spacing: 1.2),
            ),
            Expanded(
              child: Text(text,
                  style: const TextStyle(
                      fontFamily: Type.serif, fontSize: 15, height: 1.4)),
            ),
          ],
        ),
      );

  @override
  Widget build(BuildContext context) {
    if (!_loaded) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return Scaffold(
      appBar: AppBar(title: const Text('Species ID')),
      body: ListView(
        padding: const EdgeInsets.all(Metrics.gutter),
        children: [
          const Text(
            'The app never names a plant for you. It can offer suggestions, '
            'with its reasons, and you decide. Nothing is sent anywhere until '
            'you ask for an identification on a specific photo.',
            style: TextStyle(fontFamily: Type.serif, fontSize: 15.5, height: 1.45),
          ),
          const SizedBox(height: 22),

          // ── Pl@ntNet ────────────────────────────────────────────────
          const MonoLabel('Pl@ntNet · photo identification',
              size: 9, spacing: 1.8),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Press.paperRaised,
              border: Border.all(color: Press.ink, width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Diamond(
                        size: 11,
                        color: _hasPlantNet ? Press.sage : Press.inkSoft,
                        filled: _hasPlantNet),
                    const SizedBox(width: 8),
                    MonoLabel(_hasPlantNet ? 'Key saved' : 'No key yet',
                        size: 10, spacing: 1.4),
                    const Spacer(),
                    if (_hasPlantNet)
                      TextButton(
                        onPressed: () async {
                          await _keys.setPlantNetKey(null);
                          _load();
                        },
                        child: const Text('REMOVE'),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'Pl@ntNet is a non-profit run by French research '
                  'institutes. It identifies from the photograph alone.',
                  style: TextStyle(
                      fontFamily: Type.serif, fontSize: 15, height: 1.45),
                ),
                const SizedBox(height: 12),
                const MonoLabel('Getting a key', size: 9, spacing: 1.6),
                const SizedBox(height: 6),
                _step(1, 'Go to my.plantnet.org in a browser.'),
                _step(2, 'Create a free account and confirm your email.'),
                _step(3,
                    'Open Settings on that site — your API key is shown there.'),
                _step(4, 'Copy it and paste it below.'),
                const SizedBox(height: 10),
                const Text(
                  'The free tier allows 500 identifications a day, which is '
                  'far more than a person walking their own land will use. '
                  'Commercial use beyond that needs a contract with them.',
                  style: TextStyle(
                      fontFamily: Type.serif, fontSize: 14, height: 1.4),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _plantNetController,
                  obscureText: true,
                  decoration: const InputDecoration(
                      labelText: 'Pl@ntNet API key', isDense: true),
                ),
                const SizedBox(height: 10),
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: _savePlantNet,
                    child: const Text('SAVE KEY'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── LLM re-rank ─────────────────────────────────────────────
          const MonoLabel('Second opinion · your own AI account',
              size: 9, spacing: 1.8),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Press.paperRaised,
              border: Border.all(color: Press.ink, width: 1.5),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Diamond(
                        size: 11,
                        color: _hasLlm ? Press.sage : Press.inkSoft,
                        filled: _hasLlm),
                    const SizedBox(width: 8),
                    MonoLabel(_hasLlm ? 'Key saved' : 'No key yet',
                        size: 10, spacing: 1.4),
                    const Spacer(),
                    if (_hasLlm)
                      TextButton(
                        onPressed: () async {
                          await _keys.setLlmKey(null);
                          _load();
                        },
                        child: const Text('REMOVE'),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                const Text(
                  'This is the part that knows your ground. It sees the '
                  'photograph along with the county, the zone, the soil, the '
                  'month, and every species you have already recorded or '
                  'planted here — then ranks the candidates and tells you '
                  'why, so you can disagree with it.',
                  style: TextStyle(
                      fontFamily: Type.serif, fontSize: 15, height: 1.45),
                ),
                const SizedBox(height: 12),
                const MonoLabel('Getting a key', size: 9, spacing: 1.6),
                const SizedBox(height: 6),
                _step(1,
                    'Anthropic: console.anthropic.com → API keys → Create key. '
                    'OpenAI: platform.openai.com → API keys.'),
                _step(2, 'You pay that provider directly for what you use.'),
                _step(3, 'Paste the key below and pick the provider.'),
                const SizedBox(height: 8),
                const RailNote(
                  color: Press.oxblood,
                  body: 'A Claude Pro or ChatGPT Plus subscription is not API '
                      'access. API keys are billed separately, by usage.',
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<LlmProvider>(
                  initialValue: _provider,
                  decoration:
                      const InputDecoration(labelText: 'Provider', isDense: true),
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
                const SizedBox(height: 10),
                TextField(
                  controller: _llmKeyController,
                  obscureText: true,
                  decoration: InputDecoration(
                      labelText: _hasLlm ? 'Replace API key' : 'API key',
                      isDense: true),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _modelController,
                  decoration:
                      const InputDecoration(labelText: 'Model', isDense: true),
                ),
                if (_provider == LlmProvider.custom) ...[
                  const SizedBox(height: 10),
                  TextField(
                    controller: _baseUrlController,
                    decoration: const InputDecoration(
                        labelText: 'Base URL (OpenAI-compatible)',
                        isDense: true),
                  ),
                ],
                const SizedBox(height: 12),
                SizedBox(
                  height: 52,
                  child: FilledButton(
                    onPressed: _saveLlm,
                    child: const Text('SAVE'),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 22),
          const Text(
            'What leaves the phone when you ask for an identification: the '
            'one photograph, and a description of the place — county, zone, '
            'soil, month, and the species list for this property. Coordinates '
            'are rounded to about a kilometre. Nothing else, and nothing at '
            'all unless you ask.',
            style: TextStyle(fontFamily: Type.serif, fontSize: 14, height: 1.45),
          ),
          const SizedBox(height: 8),
          const MonoLabel(
              'Keys are held in the phone\'s keystore — never in the '
              'database, a backup, or an export.',
              size: 9,
              opacity: 0.7),
        ],
      ),
    );
  }
}
