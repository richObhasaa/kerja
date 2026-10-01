/// Klien REST untuk backend Google Apps Script.
///
/// Kontrak lengkap (action, field, kode error) ada di `gas/README.md`.
library;

import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/models.dart';

enum JobStatus {
  fresh('NEW', 'Baru'),
  viewed('VIEWED', 'Dilihat'),
  saved('SAVED', 'Disimpan'),
  applied('APPLIED', 'Dilamar'),
  rejected('REJECTED', 'Ditolak');

  const JobStatus(this.wire, this.label);

  /// Nilai yang dikirim ke/dari Google Apps Script.
  final String wire;

  /// Label untuk ditampilkan di UI.
  final String label;

  static JobStatus fromWire(Object? value, {JobStatus fallback = JobStatus.fresh}) {
    final v = value?.toString().trim().toUpperCase();
    for (final s in JobStatus.values) {
      if (s.wire == v) return s;
    }
    return fallback;
  }
}

class GasException implements Exception {
  GasException(this.code, this.message, {this.statusCode});

  final String code;
  final String message;
  final int? statusCode;

  @override
  String toString() => 'GasException($code${statusCode == null ? '' : ', http $statusCode'}): $message';
}

/// Loker tersimpan di `Jobs_Log`, hasil `list_jobs` / `get_job`.
class StoredJob {
  const StoredJob({
    required this.id,
    required this.title,
    required this.company,
    required this.location,
    required this.jobUrl,
    required this.matchScore,
    required this.matchLevel,
    required this.status,
    this.matchReason = '',
    this.keyMatchingSkills = const [],
    this.missingRequirements = const [],
    this.createdAt = '',
    this.updatedAt = '',
    this.tailoredSummary,
    this.coverLetter,
  });

  final String id;
  final String title;
  final String company;
  final String location;
  final String jobUrl;
  final int matchScore;
  final MatchLevel matchLevel;
  final JobStatus status;
  final String matchReason;
  final List<String> keyMatchingSkills;
  final List<String> missingRequirements;
  final String createdAt;
  final String updatedAt;

  /// Hanya terisi pada `get_job`; `list_jobs` sengaja tidak mengirimnya.
  final String? tailoredSummary;
  final String? coverLetter;

  factory StoredJob.fromJson(Map<String, dynamic> json) => StoredJob(
        id: (json['id'] ?? '').toString(),
        title: (json['title'] ?? '').toString(),
        company: (json['company'] ?? '').toString(),
        location: (json['location'] ?? '').toString(),
        jobUrl: (json['job_url'] ?? '').toString(),
        matchScore: _toInt(json['match_score']),
        matchLevel: MatchLevel.fromWire(json['match_level'],
            fallback: MatchLevel.fromScore(_toInt(json['match_score']))),
        status: JobStatus.fromWire(json['status']),
        matchReason: (json['match_reason'] ?? '').toString(),
        keyMatchingSkills: _toStringList(json['key_matching_skills']),
        missingRequirements: _toStringList(json['missing_requirements']),
        createdAt: (json['created_at'] ?? '').toString(),
        updatedAt: (json['updated_at'] ?? '').toString(),
        tailoredSummary: json['tailored_summary']?.toString(),
        coverLetter: json['cover_letter']?.toString(),
      );
}

class AppliedRecord {
  const AppliedRecord({
    required this.appliedAt,
    required this.jobUrl,
    required this.company,
    required this.tailoredSummary,
  });

  final String appliedAt;
  final String jobUrl;
  final String company;
  final String tailoredSummary;

  factory AppliedRecord.fromJson(Map<String, dynamic> json) => AppliedRecord(
        appliedAt: (json['applied_at'] ?? '').toString(),
        jobUrl: (json['job_url'] ?? '').toString(),
        company: (json['company'] ?? '').toString(),
        tailoredSummary: (json['tailored_summary'] ?? '').toString(),
      );
}

class FilterNewResult {
  const FilterNewResult({
    required this.received,
    required this.newJobs,
    required this.duplicates,
  });

  final int received;
  final List<JobPosting> newJobs;
  final List<DuplicateJob> duplicates;

  int get newCount => newJobs.length;
  int get duplicateCount => duplicates.length;
}

class DuplicateJob {
  const DuplicateJob({required this.jobUrl, required this.reason, this.existingId, this.existingStatus});

  final String jobUrl;
  final String reason;
  final String? existingId;
  final JobStatus? existingStatus;

  factory DuplicateJob.fromJson(Map<String, dynamic> json) => DuplicateJob(
        jobUrl: (json['job_url'] ?? '').toString(),
        reason: (json['reason'] ?? '').toString(),
        existingId: json['existing_id']?.toString(),
        existingStatus: json['existing_status'] == null
            ? null
            : JobStatus.fromWire(json['existing_status'], fallback: JobStatus.fresh),
      );
}

class SaveAnalysisResult {
  const SaveAnalysisResult({
    required this.saved,
    required this.createdCount,
    required this.updatedCount,
    required this.createdIds,
  });

  final int saved;
  final int createdCount;
  final int updatedCount;
  final List<String> createdIds;
}

class JobListResult {
  const JobListResult({required this.total, required this.jobs, required this.offset});

  final int total;
  final List<StoredJob> jobs;
  final int offset;

  bool get hasMore => offset + jobs.length < total;
}

class HealthStatus {
  const HealthStatus({
    required this.service,
    required this.spreadsheetId,
    required this.tokenConfigured,
    required this.time,
  });

  final String service;
  final String spreadsheetId;
  final bool tokenConfigured;
  final String time;

  factory HealthStatus.fromJson(Map<String, dynamic> json) => HealthStatus(
        service: (json['service'] ?? '').toString(),
        spreadsheetId: (json['spreadsheet_id'] ?? '').toString(),
        tokenConfigured: json['token_configured'] == true,
        time: (json['time'] ?? '').toString(),
      );
}

/// Pasangan loker + hasil analisis Gemini yang siap disimpan ke sheet.
///
/// [posting] tetap dikirim terpisah karena `CareerAnalysisResult.jobInfo`
/// tidak memuat URL, padahal `job_url` adalah kunci upsert di GAS.
typedef AnalysisEntry = ({JobPosting posting, CareerAnalysisResult analysis});

class GasClient {
  GasClient({
    required String baseUrl,
    required this.token,
    http.Client? httpClient,
    this.timeout = const Duration(seconds: 60),
  })  : _client = httpClient ?? http.Client(),
        baseUrl = _normalizeBaseUrl(baseUrl);

  /// URL Web App GAS, berakhiran `/exec`.
  final String baseUrl;
  final String token;
  final Duration timeout;

  final http.Client _client;
  static const int _maxRedirects = 5;

  static String _normalizeBaseUrl(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) {
      throw GasException('bad_request', 'URL Google Apps Script belum diisi.');
    }
    // GAS membedakan /exec (jalankan) dan /dev (mode pengembangan).
    if (!trimmed.endsWith('/exec') && !trimmed.endsWith('/dev')) {
      throw GasException(
        'bad_request',
        'URL GAS harus berakhiran /exec. Dapatkan dari Deploy > Manage deployments.',
      );
    }
    return trimmed;
  }

  // ------------------------------------------------------------------ actions

  Future<HealthStatus> health() async {
    final data = await _call('health', auth: false);
    return HealthStatus.fromJson(data);
  }

  Future<void> bootstrap() => _call('bootstrap');

  /// Step 3 alur harian: buang URL yang sudah tercatat sebelum panggil Gemini.
  Future<FilterNewResult> filterNew(List<JobPosting> jobs) async {
    final data = await _call('filter_new', body: {
      'jobs': jobs
          .map((j) => {
                'title': j.title,
                'company': j.company,
                'location': j.location,
                'job_url': j.jobUrl,
                'description': j.description,
              })
          .toList(),
    });

    return FilterNewResult(
      received: _toInt(data['received']),
      newJobs: _mapList(data['new_jobs']).map(JobPosting.fromJson).toList(),
      duplicates: _mapList(data['duplicates']).map(DuplicateJob.fromJson).toList(),
    );
  }

  /// Step 5 alur harian: simpan hasil analisis. Upsert by URL di sisi server.
  Future<SaveAnalysisResult> saveAnalysis(List<AnalysisEntry> entries) async {
    final data = await _call('save_analysis', body: {
      'jobs': entries
          .map((e) => {
                'job_url': e.posting.jobUrl,
                'title': e.posting.title,
                'company': e.posting.company,
                'location': e.posting.location,
                'analysis': e.analysis.toJson(),
              })
          .toList(),
    });

    return SaveAnalysisResult(
      saved: _toInt(data['saved']),
      createdCount: _toInt(data['created_count']),
      updatedCount: _toInt(data['updated_count']),
      createdIds: _mapList(data['created'])
          .map((e) => (e['id'] ?? '').toString())
          .where((id) => id.isNotEmpty)
          .toList(),
    );
  }

  Future<JobListResult> listJobs({
    List<JobStatus>? status,
    List<JobStatus>? excludeStatus,
    int? minScore,
    String? search,
    int limit = 50,
    int offset = 0,
  }) async {
    final data = await _call('list_jobs', body: {
      if (status != null && status.isNotEmpty)
        'status': status.map((s) => s.wire).join(','),
      if (excludeStatus != null && excludeStatus.isNotEmpty)
        'exclude_status': excludeStatus.map((s) => s.wire).join(','),
      'min_score': ?minScore,
      if (search != null && search.trim().isNotEmpty) 'search': search.trim(),
      'limit': limit,
      'offset': offset,
    });

    return JobListResult(
      total: _toInt(data['total']),
      offset: _toInt(data['offset']),
      jobs: _mapList(data['jobs']).map(StoredJob.fromJson).toList(),
    );
  }

  /// Mengambil detail lengkap termasuk `cover_letter` dan `tailored_summary`.
  Future<StoredJob> getJob({String? id, String? jobUrl}) async {
    final data = await _call('get_job', body: {
      'id': ?id,
      'job_url': ?jobUrl,
    });
    final job = data['job'];
    if (job is! Map<String, dynamic>) {
      throw GasException('internal_error', 'Respons get_job tidak memuat field `job`.');
    }
    return StoredJob.fromJson(job);
  }

  Future<StoredJob> updateStatus({
    String? id,
    String? jobUrl,
    required JobStatus status,
    String? tailoredSummary,
  }) async {
    await _call('update_status', body: {
      'id': ?id,
      'job_url': ?jobUrl,
      'status': status.wire,
      'tailored_summary': ?tailoredSummary,
    });
    return getJob(id: id, jobUrl: jobUrl);
  }

  /// Dipanggil setelah pengguna submit manual di WebView.
  Future<void> markApplied({String? id, String? jobUrl, String? tailoredSummary}) async {
    await _call('mark_applied', body: {
      'id': ?id,
      'job_url': ?jobUrl,
      'tailored_summary': ?tailoredSummary,
    });
  }

  Future<List<AppliedRecord>> listApplied({int limit = 50}) async {
    final data = await _call('list_applied', body: {'limit': limit});
    return _mapList(data['applications']).map(AppliedRecord.fromJson).toList();
  }

  // ---------------------------------------------------------------- transport

  Future<Map<String, dynamic>> _call(
    String action, {
    Map<String, dynamic>? body,
    bool auth = true,
  }) async {
    final payload = <String, dynamic>{
      'action': action,
      if (auth) 'token': token,
      ...?body,
    };

    final request = http.Request('POST', Uri.parse(baseUrl))
      ..body = jsonEncode(payload)
      // text/plain, bukan application/json: GAS tidak melayani CORS preflight.
      ..headers['Content-Type'] = 'text/plain; charset=utf-8';

    final response = await _sendFollowingRedirects(request);

    if (response.body.isEmpty) {
      throw GasException(
        'empty_response',
        'GAS membalas HTTP ${response.statusCode} tanpa isi. '
        'Pastikan deployment aktif dan akses disetel ke "Anyone".',
        statusCode: response.statusCode,
      );
    }

    final Object? decoded;
    try {
      decoded = jsonDecode(response.body);
    } on FormatException {
      throw GasException(
        'not_json',
        'Balasan GAS bukan JSON (HTTP ${response.statusCode}). '
        'Kemungkinan besar URL salah atau deployment mengarah ke versi lama.',
        statusCode: response.statusCode,
      );
    }

    if (decoded is! Map<String, dynamic>) {
      throw GasException('not_json', 'Balasan GAS bukan objek JSON.');
    }
    if (decoded['ok'] != true) {
      final error = decoded['error'];
      final map = error is Map<String, dynamic> ? error : const {};
      throw GasException(
        (map['code'] ?? 'internal_error').toString(),
        (map['message'] ?? 'GAS mengembalikan kegagalan tanpa pesan.').toString(),
        statusCode: response.statusCode,
      );
    }

    final data = decoded['data'];
    return data is Map<String, dynamic> ? data : <String, dynamic>{};
  }

  /// Mengikuti redirect 3xx secara manual sambil mempertahankan method dan body.
  ///
  /// Wajib untuk GAS: URL `/exec` membalas 302, sementara `dart:io` hanya
  /// mengikuti redirect otomatis untuk POST berstatus 303 (lihat
  /// `_HttpClientResponse.isRedirect` di SDK). Tanpa ini, POST ke GAS berakhir
  /// dengan body kosong.
  Future<http.Response> _sendFollowingRedirects(http.Request request) async {
    var current = request;
    final seen = <String>{};

    for (var hop = 0; hop <= _maxRedirects; hop++) {
      current.followRedirects = false;
      final streamed = await _client.send(current).timeout(timeout);
      final response = await http.Response.fromStream(streamed);

      final location = response.headers['location'];
      if (!_isRedirect(response.statusCode) || location == null || location.isEmpty) {
        return response;
      }

      final next = current.url.resolve(location).toString();
      if (!seen.add(next)) {
        throw GasException('redirect_loop', 'GAS mengarahkan berulang ke URL yang sama: $next');
      }
      current = _retarget(current, Uri.parse(next), response.statusCode);
    }

    throw GasException('redirect_limit', 'Terlalu banyak redirect dari GAS (maks $_maxRedirects).');
  }

  /// Mengikuti redirect sambil meniru perilaku klien HTTP pada umumnya.
  ///
  /// Untuk 301/302/303 yang berasal dari POST, method diganti jadi GET dan
  /// body dibuang: URL echo GAS (`script.googleusercontent.com/macros/echo`)
  /// menyajikan hasil `doPost` lewat GET, dan mem-POST ulang ke sana justru
  /// dibalas halaman login Google. Untuk 307/308 method dan body dipertahankan
  /// sesuai spesifikasi.
  static http.Request _retarget(http.Request source, Uri url, int status) {
    final dropBody =
        (status == 301 || status == 302 || status == 303) && source.method == 'POST';
    final request = http.Request(dropBody ? 'GET' : source.method, url)
      ..headers.addAll(source.headers)
      ..persistentConnection = source.persistentConnection
      ..followRedirects = false
      ..maxRedirects = 0;
    if (!dropBody) request.bodyBytes = source.bodyBytes;
    return request;
  }

  static bool _isRedirect(int status) =>
      status == 301 || status == 302 || status == 303 || status == 307 || status == 308;

  void close() => _client.close();
}

int _toInt(Object? value) {
  if (value is int) return value;
  if (value is num) return value.round();
  return int.tryParse(value?.toString() ?? '') ?? 0;
}

List<Map<String, dynamic>> _mapList(Object? value) {
  if (value is! List) return const [];
  return value.whereType<Map<String, dynamic>>().toList();
}

List<String> _toStringList(Object? value) {
  if (value is List) {
    return value.map((e) => e.toString().trim()).where((e) => e.isNotEmpty).toList();
  }
  // GAS menyimpan array sebagai teks dipisah ' | '.
  return value
          ?.toString()
          .split('|')
          .map((e) => e.trim())
          .where((e) => e.isNotEmpty)
          .toList() ??
      const [];
}
