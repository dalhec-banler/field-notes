import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

import 'id_keys.dart';
import 'id_models.dart';

/// LLM re-rank (spec §5, layer 3) — the differentiator.
///
/// A vision model sees a photograph. This sees the photograph *and* the
/// county, the zone, the soil series, the month, and what you have already
/// recorded and planted on this ground. It reorders the candidates and says
/// why, in words the user reads and judges.
///
/// The user's own key, the user's own account, provider of their choosing.
/// Nothing is sent unless they ask for an identification.
class LlmClient {
  LlmClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  /// The shape we ask for back. Same schema whichever provider answers.
  static const _schema = {
    'type': 'object',
    'properties': {
      'candidates': {
        'type': 'array',
        'items': {
          'type': 'object',
          'properties': {
            'scientific_name': {'type': 'string'},
            'common_name': {'type': 'string'},
            'confidence': {'type': 'number'},
            'reasoning': {'type': 'string'},
          },
          'required': [
            'scientific_name',
            'common_name',
            'confidence',
            'reasoning'
          ],
          'additionalProperties': false,
        },
      },
    },
    'required': ['candidates'],
    'additionalProperties': false,
  };

  static const _system =
      'You help a land steward identify plants on their own property. '
      'You are given a photograph, the place it was taken, and what the '
      'steward has already recorded and planted there.\n\n'
      'Rank the most likely species. Use the local context as real evidence: '
      'a species already recorded or planted on this ground is far more '
      'likely than a lookalike that has never been seen there, and season, '
      'soil and zone all constrain what can be in the frame. Where candidate '
      'names are supplied by another identifier, you may reorder them, drop '
      'implausible ones, and add species they missed.\n\n'
      'In "reasoning", give one or two plain sentences a person in the field '
      'can weigh — the diagnostic features you can actually see, and what '
      'local context supports or contradicts. If a confusable species cannot '
      'be ruled out from the photograph, say so and say what to look at. '
      'Never claim certainty you do not have; a lower confidence with an '
      'honest reason is more useful than a confident guess.';

  /// Re-rank [priors] (may be empty) against the photograph and context.
  Future<List<IdCandidate>> rerank({
    required File photo,
    required IdContext context,
    required List<IdCandidate> priors,
    required LlmProvider provider,
    required String apiKey,
    required String model,
    required String baseUrl,
  }) async {
    final bytes = await photo.readAsBytes();
    final prompt = _prompt(context, priors);
    final raw = switch (provider) {
      LlmProvider.anthropic =>
        await _anthropic(bytes, prompt, apiKey, model, baseUrl),
      _ => await _openAiCompatible(bytes, prompt, apiKey, model, baseUrl),
    };
    return _parse(raw);
  }

  String _prompt(IdContext context, List<IdCandidate> priors) {
    final b = StringBuffer()
      ..writeln('Where this photograph was taken:')
      ..writeln(context.describe());
    if (priors.isNotEmpty) {
      b
        ..writeln()
        ..writeln('Another identifier suggested, best first:');
      for (final c in priors) {
        final pct = c.score == null
            ? ''
            : ' (${(c.score! * 100).toStringAsFixed(0)}%)';
        b.writeln('- ${c.name}$pct');
      }
    } else {
      b
        ..writeln()
        ..writeln('No other identifier was available; work from the '
            'photograph and the context alone.');
    }
    b
      ..writeln()
      ..writeln('Give up to five candidates, best first.');
    return b.toString();
  }

  Future<String> _anthropic(Uint8List image, String prompt, String key,
      String model, String baseUrl) async {
    final uri = Uri.parse('${_trim(baseUrl)}/v1/messages');
    final res = await _client
        .post(uri,
            headers: {
              'content-type': 'application/json',
              'x-api-key': key,
              'anthropic-version': '2023-06-01',
            },
            body: jsonEncode({
              'model': model,
              'max_tokens': 4000,
              'system': _system,
              // Adaptive thinking: this is a judgement call about evidence,
              // and the reasoning is the part the user actually reads.
              'thinking': {'type': 'adaptive'},
              'output_config': {
                'effort': 'medium',
                'format': {'type': 'json_schema', 'schema': _schema},
              },
              'messages': [
                {
                  'role': 'user',
                  'content': [
                    {
                      'type': 'image',
                      'source': {
                        'type': 'base64',
                        'media_type': 'image/jpeg',
                        'data': base64Encode(image),
                      },
                    },
                    {'type': 'text', 'text': prompt},
                  ],
                }
              ],
            }))
        .timeout(const Duration(seconds: 90));

    if (res.statusCode == 401 || res.statusCode == 403) {
      throw const LlmException('That API key was rejected. Check it in Settings.');
    }
    if (res.statusCode != 200) {
      throw LlmException(_errorFrom(res.body, res.statusCode));
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    // A safety decline is a 200 with stop_reason "refusal" — check before
    // reading content.
    if (body['stop_reason'] == 'refusal') {
      throw const LlmException(
          'The model declined to answer this one. Try another photo.');
    }
    final content = (body['content'] as List?) ?? const [];
    for (final block in content) {
      if (block is Map && block['type'] == 'text') {
        return block['text'] as String? ?? '';
      }
    }
    return '';
  }

  Future<String> _openAiCompatible(Uint8List image, String prompt, String key,
      String model, String baseUrl) async {
    final uri = Uri.parse('${_trim(baseUrl)}/v1/chat/completions');
    final res = await _client
        .post(uri,
            headers: {
              'content-type': 'application/json',
              'authorization': 'Bearer $key',
            },
            body: jsonEncode({
              'model': model,
              'messages': [
                {'role': 'system', 'content': _system},
                {
                  'role': 'user',
                  'content': [
                    {
                      'type': 'image_url',
                      'image_url': {
                        'url': 'data:image/jpeg;base64,${base64Encode(image)}'
                      },
                    },
                    {'type': 'text', 'text': prompt},
                  ],
                }
              ],
              'response_format': {
                'type': 'json_schema',
                'json_schema': {
                  'name': 'candidates',
                  'schema': _schema,
                  'strict': true,
                },
              },
            }))
        .timeout(const Duration(seconds: 90));

    if (res.statusCode == 401 || res.statusCode == 403) {
      throw const LlmException('That API key was rejected. Check it in Settings.');
    }
    if (res.statusCode != 200) {
      throw LlmException(_errorFrom(res.body, res.statusCode));
    }
    final body = jsonDecode(res.body) as Map<String, dynamic>;
    final choices = (body['choices'] as List?) ?? const [];
    if (choices.isEmpty) return '';
    final message = (choices.first as Map)['message'] as Map?;
    return message?['content'] as String? ?? '';
  }

  String _errorFrom(String body, int status) {
    try {
      final decoded = jsonDecode(body);
      if (decoded is Map) {
        final err = decoded['error'];
        if (err is Map && err['message'] is String) {
          return err['message'] as String;
        }
      }
    } catch (_) {}
    return 'Identification service error $status';
  }

  List<IdCandidate> _parse(String raw) {
    if (raw.trim().isEmpty) return const [];
    Map<String, dynamic>? decoded;
    try {
      decoded = jsonDecode(raw) as Map<String, dynamic>;
    } catch (_) {
      // Some providers wrap JSON in prose despite the schema; salvage it.
      final start = raw.indexOf('{');
      final end = raw.lastIndexOf('}');
      if (start >= 0 && end > start) {
        try {
          decoded = jsonDecode(raw.substring(start, end + 1))
              as Map<String, dynamic>;
        } catch (_) {}
      }
    }
    final list = (decoded?['candidates'] as List?) ?? const [];
    final out = <IdCandidate>[];
    for (var i = 0; i < list.length; i++) {
      final c = list[i];
      if (c is! Map) continue;
      final name = c['scientific_name'] as String?;
      if (name == null || name.trim().isEmpty) continue;
      final common = (c['common_name'] as String?)?.trim();
      out.add(IdCandidate(
        name: name.trim(),
        commonName: (common == null || common.isEmpty) ? null : common,
        source: 'llm_rerank',
        score: (c['confidence'] as num?)?.toDouble(),
        reasoning: (c['reasoning'] as String?)?.trim(),
        rank: i + 1,
      ));
    }
    return out;
  }

  String _trim(String url) =>
      url.endsWith('/') ? url.substring(0, url.length - 1) : url;

  void close() => _client.close();
}

class LlmException implements Exception {
  const LlmException(this.message);
  final String message;
  @override
  String toString() => message;
}
