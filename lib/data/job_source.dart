/// Aggregator lowongan dari beberapa API sekaligus.
///
/// Deduplikasi URL TIDAK dilakukan di sini secara sengaja: satu-satunya
/// tempat yang menormalisasi URL adalah `filter_new` di Google Apps Script.
/// Menduplikasi aturan normalisasi ke Dart berarti dua implementasi yang bisa
/// menyimpang, dan penyimpangan itu membuat anti-duplikat gagal diam-diam.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/models.dart';
import '../core/settings.dart';

class JobSourceException implements Exception {
  JobSourceException(this.source, this.message);

  final String source;
  final String message;

  @override
  String toString() => '$source: $message';
}

abstract class JobSource {
  /// Nama sumber, dipakai untuk label error di UI.
  String get name;

  Future<List<JobPosting>> search({
    required String query,
    int limit = 25,
  });
}

/// Menggabungkan hasil beberapa sumber.
class AggregateResult {
  const AggregateResult({required this.jobs, required this.errors});

  final List<JobPosting> jobs;
  final List<JobSourceException> errors;

  bool get allSourcesFailed => errors.isNotEmpty && jobs.isEmpty;

  Map<String, int> get countBySource => jobs.fold(<String, int>{}, (acc, job) {
        final key = job.source;
        acc[key] = (acc[key] ?? 0) + 1;
        return acc;
      });
}

class JobAggregator {
  JobAggregator(this.sources);

  final List<JobSource> sources;

  /// Menjalankan semua sumber paralel. Sumber yang gagal tidak menggagalkan
  /// keseluruhan — errornya dikumpulkan supaya tetap bisa dilaporkan ke pengguna.
  Future<AggregateResult> fetch(JobSearchPrefs prefs, {int limitPerQuery = 25}) async {
    final jobs = <JobPosting>[];
    final errors = <JobSourceException>[];

    final tasks = <Future<void>>[];
    for (final source in sources) {
      for (final category in prefs.categories.where((c) => c.trim().isNotEmpty)) {
        tasks.add(() async {
          try {
            final found = await source.search(
              query: buildQuery(category, prefs),
              limit: limitPerQuery,
            );
            jobs.addAll(found);
          } on JobSourceException catch (e) {
            errors.add(e);
          } catch (e) {
            errors.add(JobSourceException(source.name, e.toString()));
          }
        }());
      }
    }

    await Future.wait(tasks);
    return AggregateResult(jobs: jobs, errors: errors);
  }
}

/// Kata kunci pencarian: kategori + lokasi (atau "Remote").
String buildQuery(String category, JobSearchPrefs prefs) {
  final where = prefs.remoteOnly ? 'Remote' : prefs.location.trim();
  final base = category.trim();
  return where.isEmpty ? base : '$base $where';
}

/// Membuang entri tanpa URL — tanpa URL loker tidak bisa di-dedup maupun dilamar.
List<JobPosting> _dropWithoutUrl(List<JobPosting> jobs) =>
    jobs.where((j) => j.jobUrl.trim().isNotEmpty).toList(growable: false);

// --------------------------------------------------------------------- JSearch

/// RapidAPI JSearch: mencakup JobStreet, LinkedIn, Glints, Kalibrr, KitaLulus.
class JSearchSource implements JobSource {
  JSearchSource({
    required String apiKey,
    http.Client? httpClient,
    this.datePosted = 'month',
    this.timeout = const Duration(seconds: 45),
  })  : _apiKey = apiKey.trim(),
        _client = httpClient ?? http.Client() {
    if (_apiKey.isEmpty) {
      throw JobSourceException(name, 'JSearch API Key belum diisi.');
    }
  }

  static const _host = 'jsearch.p.rapidapi.com';

  @override
  String get name => 'JSearch';

  final String _apiKey;
  final http.Client _client;

  /// `all`, `today`, `3days`, `week`, `month`. Default lebar karena jendela
  /// sempit untuk query magang Indonesia sering benar-benar kosong, dan
  /// pengulangan tidak berbahaya — GAS membuang URL yang sudah tercatat.
  final String datePosted;
  final Duration timeout;

  @override
  Future<List<JobPosting>> search({required String query, int limit = 25}) async {
    // Route "Job Search" pada JSearch v5 adalah /search-v2. Path /search lama
    // sudah dihapus sisi provider dan dibalas "Endpoint '/search' does not
    // exist" — persis error yang muncul di perangkat pengguna.
    final uri = Uri.https(_host, '/search-v2', {
      'query': query,
      'page': '1',
      'num_pages': '1',
      'date_posted': datePosted,
    });

    final response = await _get(uri);
    final body = _decodeJson(response, name);
    final status = (body['status'] ?? '').toString();
    if (status.toUpperCase() != 'OK') {
      throw JobSourceException(
        name,
        'JSearch membalas status "$status" (HTTP ${response.statusCode}): '
        '${(body['message'] ?? '').toString()}',
      );
    }

    final data = body['data'];
    if (data is! List) return const [];

    final jobs = data.whereType<Map<String, dynamic>>().map((item) {
      final city = _first(item, ['job_city', 'city']);
      final country = _first(item, ['job_country', 'country']);
      final fromParts = [city, country].where((p) => p.isNotEmpty).join(', ');

      return JobPosting(
        title: _first(item, ['job_title', 'title']),
        company: _first(item, ['employer_name', 'company', 'job_publisher']),
        location: fromParts.isNotEmpty ? fromParts : _first(item, ['location']),
        description: _first(item, ['job_description', 'description']),
        jobUrl: _first(item, ['job_apply_link', 'apply_link', 'url']),
        source: name,
      );
    }).toList();

    final kept = _dropWithoutUrl(jobs).take(limit).toList(growable: false);

    // Item masuk tapi tak satu pun punya URL = provider mengganti nama field.
    // Lebih baik jadi error terang daripada nol yang tidak bisa dijelaskan.
    if (kept.isEmpty && jobs.isNotEmpty) {
      throw JobSourceException(
        name,
        'JSearch mengirim ${jobs.length} item tanpa field URL yang dikenali '
        '(job_apply_link/apply_link/url). Kemungkinan provider mengubah skema respons.',
      );
    }
    return kept;
  }

  /// Mengambil nilai pertama yang tidak kosong dari beberapa nama field.
  static String _first(Map<String, dynamic> item, List<String> keys) {
    for (final key in keys) {
      final value = item[key];
      final text = value?.toString().trim() ?? '';
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  Future<http.Response> _get(Uri uri) async {
    try {
      return await _client
          .get(uri, headers: {'X-RapidAPI-Key': _apiKey, 'X-RapidAPI-Host': _host})
          .timeout(timeout);
    } on TimeoutException {
      throw JobSourceException(name, 'JSearch tidak merespons dalam ${timeout.inSeconds} detik.');
    } catch (e) {
      throw JobSourceException(name, 'Gagal menghubungi JSearch: $e');
    }
  }
}

// --------------------------------------------------------------------- SerpAPI

/// SerpAPI Google Jobs: mencakup LinkedIn, Glassdoor, JobStreet, Karir.com.
class SerpApiSource implements JobSource {
  SerpApiSource({
    required String apiKey,
    http.Client? httpClient,
    this.gl = 'id',
    this.hl = 'id',
    this.timeout = const Duration(seconds: 45),
  })  : _apiKey = apiKey.trim(),
        _client = httpClient ?? http.Client() {
    if (_apiKey.isEmpty) {
      throw JobSourceException(name, 'SerpAPI Key belum diisi.');
    }
  }

  static const _host = 'serpapi.com';

  @override
  String get name => 'SerpAPI';

  final String _apiKey;
  final http.Client _client;

  /// Kode negara & bahasa hasil Google.
  final String gl;
  final String hl;
  final Duration timeout;

  @override
  Future<List<JobPosting>> search({required String query, int limit = 25}) async {
    final uri = Uri.https(_host, '/search.json', {
      'engine': 'google_jobs',
      'q': query,
      'api_key': _apiKey,
      'gl': gl,
      'hl': hl,
    });

    http.Response response;
    try {
      response = await _client.get(uri).timeout(timeout);
    } on TimeoutException {
      throw JobSourceException(name, 'SerpAPI tidak merespons dalam ${timeout.inSeconds} detik.');
    } catch (e) {
      throw JobSourceException(name, 'Gagal menghubungi SerpAPI: $e');
    }

    final body = _decodeJson(response, name);

    if (response.statusCode != 200) {
      throw JobSourceException(
        name,
        'SerpAPI HTTP ${response.statusCode}: ${(body['error'] ?? body['search_metadata']?['status'] ?? '').toString()}',
      );
    }
    // SerpAPI memakai 200 + field `error` untuk key tidak valid / kuota habis.
    final apiError = body['error'];
    if (apiError is String && apiError.isNotEmpty) {
      throw JobSourceException(name, apiError);
    }

    final results = body['jobs_results'];
    if (results is! List) return const [];

    final jobs = results.whereType<Map<String, dynamic>>().map((item) {
      return JobPosting(
        title: (item['title'] ?? '').toString().trim(),
        company: (item['company_name'] ?? '').toString().trim(),
        location: (item['location'] ?? '').toString().trim(),
        description: (item['description'] ?? '').toString().trim(),
        jobUrl: (item['job_apply_link'] ?? '').toString().trim(),
        source: name,
      );
    }).toList();

    return _dropWithoutUrl(jobs).take(limit).toList(growable: false);
  }
}

// --------------------------------------------------------------------- helpers

Map<String, dynamic> _decodeJson(http.Response response, String source) {
  if (response.body.trim().isEmpty) {
    throw JobSourceException(source, 'Balasan kosong (HTTP ${response.statusCode}).');
  }
  try {
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) return decoded;
    throw JobSourceException(source, 'Balasan bukan objek JSON.');
  } on FormatException {
    throw JobSourceException(
      source,
      'Balasan bukan JSON (HTTP ${response.statusCode}). '
      'Kemungkinan API key ditolak sebelum sampai ke endpoint.',
    );
  }
}
