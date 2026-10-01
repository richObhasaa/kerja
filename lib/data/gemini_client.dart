/// Klien Gemini API untuk analisis CV vs lowongan.
///
/// Bertanggung jawab atas dua hal yang rawan: memanggil endpoint
/// `generateContent` dengan benar, dan mem-parse balasan model yang kadang
/// tidak mematuhi aturan "JSON murni" di prompt template.
library;

import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/models.dart';

class GeminiException implements Exception {
  GeminiException(this.code, this.message);

  final String code;
  final String message;

  @override
  String toString() => 'GeminiException($code): $message';
}

class GeminiClient {
  GeminiClient({
    required String apiKey,
    this.model = 'gemini-3.8-flash',
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 90),
    this.retryDelay = const Duration(seconds: 3),
  })  : _apiKey = apiKey.trim(),
        _client = httpClient ?? http.Client() {
    if (_apiKey.isEmpty) {
      throw GeminiException('bad_request', 'Gemini API Key belum diisi.');
    }
  }

  final String _apiKey;
  final String model;
  final Duration timeout;
  final http.Client _client;

  static const _endpoint = 'https://generativelanguage.googleapis.com/v1beta/models';

  /// Suhu rendah supaya skor dan struktur JSON stabil antar-jalankan.
  static const _temperature = 0.3;

  /// Longgar karena model flash generasi ini menyisihkan sebagian budget untuk
  /// "thoughts"; budget kekecilan membuat bagian teks balasannya kosong.
  static const _maxOutputTokens = 8192;

  /// Error yang layak dicoba ulang: lonjakan beban dan batas laju tier gratis.
  static const _retryableCodes = {'UNAVAILABLE', 'RESOURCE_EXHAUSTED'};
  static const int _maxAttempts = 3;

  /// Jeda dasar antar percobaan; dikalikan nomor percobaan (backoff linear).
  final Duration retryDelay;

  Uri get _uri => Uri.parse('$_endpoint/$model:generateContent');

  /// Memanggil Gemini dan mengembalikan teks mentah.
  ///
  /// Error transien (lonjakan beban / batas laju tier gratis) dicoba ulang
  /// dengan backoff linear; error lain langsung dilempar supaya pipeline
  /// mencatatnya sebagai kegagalan loker tersebut, bukan mengulang sia-sia.
  Future<String> generateText(String prompt) async {
    for (var attempt = 1;; attempt++) {
      try {
        return await _generateOnce(prompt);
      } on GeminiException catch (e) {
        if (!_retryableCodes.contains(e.code) || attempt >= _maxAttempts) rethrow;
        await Future<void>.delayed(retryDelay * attempt);
      }
    }
  }

  Future<String> _generateOnce(String prompt) async {
    final response = await _client
        .post(
          _uri,
          // Key dikirim lewat header, bukan query string, agar tidak ikut
          // tercatat di log proxy maupun riwayat URL.
          headers: {
            'Content-Type': 'application/json',
            'x-goog-api-key': _apiKey,
          },
          body: jsonEncode({
            'contents': [
              {
                'role': 'user',
                'parts': [
                  {'text': prompt}
                ],
              }
            ],
            'generationConfig': {
              // Tier gratis gemini-3.8-flash kerap membalas 503 UNAVAILABLE saat
              // beban tinggi, apa pun isi generationConfig-nya. Karena itu
              // request dibuat minimal dan generateText() mencoba ulang;
              // jaminan format JSON datang dari template prompt +
              // parseJsonObject(), bukan dari mode structured-output.
              'temperature': _temperature,
              'maxOutputTokens': _maxOutputTokens,
            },
          }),
        )
        .timeout(timeout);

    final Object? decoded = _decode(response.body, response.statusCode);
    final map = decoded is Map<String, dynamic>
        ? decoded
        : throw GeminiException('not_json', 'Balasan Gemini bukan objek JSON.');

    if (response.statusCode != 200) {
      final error = map['error'];
      final detail = error is Map<String, dynamic> ? error : const {};
      throw GeminiException(
        (detail['status'] ?? 'http_${response.statusCode}').toString(),
        (detail['message'] ?? 'Gemini mengembalikan HTTP ${response.statusCode}.').toString(),
      );
    }

    return _extractText(map);
  }

  /// [prompt] adalah hasil `buildPrompt()`. Balasan di-parse jadi
  /// [CareerAnalysisResult].
  Future<CareerAnalysisResult> analyze(String prompt) async {
    final raw = await generateText(prompt);
    final json = parseJsonObject(raw);
    return CareerAnalysisResult.fromJson(json);
  }

  String _extractText(Map<String, dynamic> body) {
    final promptFeedback = body['promptFeedback'];
    if (promptFeedback is Map<String, dynamic> && promptFeedback['blockReason'] != null) {
      throw GeminiException(
        'prompt_blocked',
        'Prompt diblokir filter keamanan Gemini: ${promptFeedback['blockReason']}',
      );
    }

    final candidates = body['candidates'];
    if (candidates is! List || candidates.isEmpty) {
      throw GeminiException('no_candidate', 'Gemini tidak mengembalikan kandidat apa pun.');
    }

    final first = candidates.first;
    if (first is! Map<String, dynamic>) {
      throw GeminiException('no_candidate', 'Struktur kandidat Gemini tidak dikenali.');
    }

    final finishReason = first['finishReason']?.toString();
    final content = first['content'];
    final parts = content is Map<String, dynamic> ? content['parts'] : null;

    final text = parts is List
        ? parts
            .whereType<Map<String, dynamic>>()
            // Model reasoning menyertakan part "thoughts" berdampingan dengan
            // jawaban; menggabungkannya akan mencemari JSON yang di-parse.
            .where((p) => p['thought'] != true)
            .map((p) => (p['text'] ?? '').toString())
            .join()
            .trim()
        : '';

    if (text.isEmpty) {
      throw GeminiException(
        'empty_response',
        finishReason == 'SAFETY' || finishReason == 'PROHIBITED_CONTENT'
            ? 'Balasan Gemini disaring oleh filter keamanan ($finishReason).'
            : 'Balasan Gemini kosong (finishReason: ${finishReason ?? 'unknown'}).',
      );
    }
    return text;
  }

  Object? _decode(String body, int statusCode) {
    if (body.trim().isEmpty) {
      throw GeminiException('empty_response', 'Gemini membalas HTTP $statusCode tanpa isi.');
    }
    try {
      return jsonDecode(body);
    } on FormatException {
      throw GeminiException(
        'not_json',
        'Balasan Gemini bukan JSON (HTTP $statusCode): ${_preview(body)}',
      );
    }
  }

  void close() => _client.close();
}

String _preview(String text) {
  final flat = text.replaceAll(RegExp(r'\s+'), ' ').trim();
  return flat.length <= 160 ? flat : '${flat.substring(0, 160)}...';
}

/// Mengambil objek JSON dari balasan model.
///
/// Prompt template sudah melarang markdown fence, dan `responseMimeType`
/// sudah disetel ke `application/json`, tapi model tetap kadang membungkus
/// output atau menambah kalimat pengantar. Tanpa pembersihan ini, seluruh
/// pipeline harian gagal hanya karena satu balasan bandel.
Map<String, dynamic> parseJsonObject(String raw) {
  final text = raw.trim();
  if (text.isEmpty) {
    throw GeminiException('empty_response', 'Tidak ada teks untuk di-parse jadi JSON.');
  }

  for (final candidate in _candidates(text)) {
    try {
      final decoded = jsonDecode(candidate);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      continue;
    }
  }

  final scanned = _scanOuterObject(text);
  if (scanned != null) {
    try {
      final decoded = jsonDecode(scanned);
      if (decoded is Map<String, dynamic>) return decoded;
    } on FormatException {
      // jatuh ke error di bawah
    }
  }

  throw GeminiException(
    'unparseable',
    'Balasan Gemini tidak mengandung JSON yang valid: ${_preview(text)}',
  );
}

/// Urutan percobaan: teks apa adanya, lalu isi markdown fence.
Iterable<String> _candidates(String text) sync* {
  yield text;

  final fence = RegExp(r'```(?:json|JSON)?\s*(.*?)\s*```', dotAll: true).firstMatch(text);
  if (fence != null) yield fence.group(1)!.trim();

  final firstBrace = text.indexOf('{');
  if (firstBrace > 0) yield text.substring(firstBrace);
}

/// Mencari objek JSON terluar dengan menghitung kedalaman kurung kurawal,
/// mengabaikan kurung yang muncul di dalam string literal.
String? _scanOuterObject(String text) {
  final start = text.indexOf('{');
  if (start == -1) return null;

  var depth = 0;
  var inString = false;
  var escaped = false;

  for (var i = start; i < text.length; i++) {
    final char = text[i];

    if (inString) {
      if (escaped) {
        escaped = false;
      } else if (char == r'\') {
        escaped = true;
      } else if (char == '"') {
        inString = false;
      }
      continue;
    }

    if (char == '"') {
      inString = true;
    } else if (char == '{') {
      depth++;
    } else if (char == '}') {
      depth--;
      if (depth == 0) return text.substring(start, i + 1);
    }
  }
  return null;
}
