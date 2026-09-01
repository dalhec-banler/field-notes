import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;

import 'id_models.dart';

/// Pl@ntNet identification (spec §5, layer 1). The user supplies their own
/// API key from my.plantnet.org; nothing is sent until they've done that and
/// asked for an identification.
///
/// The `project` is set to a regional flora rather than `all` — Pl@ntNet's
/// own documentation is explicit that this improves accuracy.
class PlantNetClient {
  PlantNetClient({http.Client? client}) : _client = client ?? http.Client();

  final http.Client _client;

  static const host = 'my-api.plantnet.org';

  /// Regional floras worth offering a Texas steward. `k-world-flora` is the
  /// safe default anywhere.
  static const projects = {
    'k-world-flora': 'World flora',
    'k-northamerica': 'North America',
    'weurope': 'Western Europe',
  };

  /// Which part of the plant the photograph shows — Pl@ntNet weights this.
  static const organs = ['leaf', 'flower', 'fruit', 'bark', 'habit', 'auto'];

  Future<List<IdCandidate>> identify({
    required List<File> photos,
    required String apiKey,
    String project = 'k-world-flora',
    String organ = 'auto',
    int maxResults = 5,
  }) async {
    final uri = Uri.https(host, '/v2/identify/$project', {
      'api-key': apiKey,
      'include-related-images': 'false',
      'no-reject': 'false',
      'nb-results': '$maxResults',
      'lang': 'en',
    });
    final request = http.MultipartRequest('POST', uri);
    // Up to five images of the same plant in one request — a leaf, the
    // flower, the bark — is how Pl@ntNet gets confident. Organs are
    // optional; when one is chosen it applies to every image.
    for (final f in photos.take(5)) {
      request.files.add(await http.MultipartFile.fromPath('images', f.path));
      if (organ != 'auto') {
        request.files.add(http.MultipartFile.fromString('organs', organ));
      }
    }

    final streamed = await _client
        .send(request)
        .timeout(const Duration(seconds: 45));
    final body = await streamed.stream.bytesToString();
    if (streamed.statusCode == 401 || streamed.statusCode == 403) {
      throw const PlantNetException(
        'Pl@ntNet rejected the key. Check it in Settings.',
      );
    }
    if (streamed.statusCode == 404) {
      // Their "no match" response, not a failure.
      return const [];
    }
    if (streamed.statusCode == 429) {
      throw const PlantNetException(
        'Pl@ntNet daily limit reached on this key. Try again tomorrow.',
      );
    }
    if (streamed.statusCode != 200) {
      throw PlantNetException('Pl@ntNet error ${streamed.statusCode}');
    }

    final data = jsonDecode(body) as Map<String, dynamic>;
    final results = (data['results'] as List?) ?? const [];
    final out = <IdCandidate>[];
    for (var i = 0; i < results.length; i++) {
      final r = results[i] as Map<String, dynamic>;
      final species = (r['species'] as Map?)?.cast<String, dynamic>();
      final name = species?['scientificNameWithoutAuthor'] as String?;
      if (name == null) continue;
      final commons = (species?['commonNames'] as List?)?.cast<String>();
      out.add(
        IdCandidate(
          name: name,
          commonName: (commons != null && commons.isNotEmpty)
              ? commons.first
              : null,
          source: 'plantnet',
          score: (r['score'] as num?)?.toDouble(),
          rank: i + 1,
        ),
      );
    }
    return out;
  }

  void close() => _client.close();
}

class PlantNetException implements Exception {
  const PlantNetException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// A tiny owned http client, so a screen can probe a key without holding a
/// whole PlantNetClient.
class HttpClientHolder {
  final _client = http.Client();
  Future<http.Response> post(Uri uri) => _client.post(uri);
  void close() => _client.close();
}
