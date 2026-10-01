/// State dashboard: memegang AppSettings + GasClient dan menyediakannya
/// sebagai ChangeNotifier supaya UI bisa rebuilt tanpa boilerplate.
library;

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../core/settings.dart';
import '../data/gas_client.dart';
import '../pipeline/daily_pipeline.dart';

class JobStore extends ChangeNotifier {
  /// [httpClient] hanya untuk tes, supaya GasClient bisa diarahkan ke mock.
  JobStore({AppSettings? settings, http.Client? httpClient})
      : _settings = settings,
        _httpClient = httpClient;

  AppSettings? _settings;
  final http.Client? _httpClient;
  GasClient? _gas;

  List<StoredJob> _jobs = const [];
  bool _loading = false;
  String? _error;
  List<String> _missingConfig = const [];
  JobStatus? _statusFilter;
  bool _initialized = false;

  List<StoredJob> get jobs => _jobs;
  bool get loading => _loading;
  String? get error => _error;
  List<String> get missingConfig => _missingConfig;
  JobStatus? get statusFilter => _statusFilter;
  bool get isConfigured => _missingConfig.isEmpty && _gas != null;

  /// Muat ulang settings. Dipanggil setiap kali pengguna keluar dari halaman
  /// Settings, karena API key atau URL GAS mungkin berubah.
  Future<void> init() async {
    _settings ??= await AppSettings.load();
    _initialized = true;

    final missing = await _settings!.missingRequirements();
    _missingConfig = missing;

    _gas?.close();
    final gasUrl = _settings!.gasUrl;
    final token = await _settings!.secret(Secret.gasToken);
    _gas = (gasUrl != null && token != null)
        ? GasClient(baseUrl: gasUrl, token: token, httpClient: _httpClient)
        : null;

    notifyListeners();
  }

  Future<void> refresh() async {
    if (!_initialized) await init();

    final gas = _gas;
    if (gas == null) {
      _error = _missingConfig.isEmpty
          ? 'Koneksi ke Google Apps Script belum diatur.'
          : 'Konfigurasi belum lengkap: ${_missingConfig.join(', ')}.';
      _jobs = const [];
      notifyListeners();
      return;
    }

    _loading = true;
    _error = null;
    notifyListeners();

    try {
      final result = await gas.listJobs(
        status: _statusFilter == null ? null : [_statusFilter!],
        limit: 200,
      );
      _jobs = result.jobs;
    } on GasException catch (e) {
      _error = e.message;
      _jobs = const [];
    } catch (e) {
      _error = 'Gagal memuat loker: $e';
      _jobs = const [];
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<void> setStatusFilter(JobStatus? status) async {
    _statusFilter = status;
    await refresh();
  }

  /// Mengambil detail lengkap (termasuk cover letter) untuk halaman apply.
  Future<StoredJob> fetchDetail(String jobId) async {
    return _requireGas().getJob(id: jobId);
  }

  Future<void> markApplied(StoredJob job) async {
    await _requireGas().markApplied(id: job.id);
    await refresh();
  }

  Future<void> setStatus(StoredJob job, JobStatus status) async {
    await _requireGas().updateStatus(id: job.id, status: status);
    await refresh();
  }

  /// Menjalankan pipeline sekarang dan mengembalikan laporannya. Berbeda dari
  /// jalur WorkManager, hasil di sini ditampilkan sebagai dialog, bukan
  /// notifikasi, karena aplikasi sedang di foreground.
  Future<PipelineReport> runPipelineNow() async {
    final settings = _settings ??= await AppSettings.load();
    final pipeline = await DailyPipeline.fromSettings(settings);
    try {
      return await pipeline.run();
    } finally {
      pipeline.close();
    }
  }

  /// Cek koneksi ke GAS, dipakai tombol "Tes Koneksi" di Settings.
  /// `health` adalah satu-satunya action yang tidak memverifikasi token.
  Future<HealthStatus> checkConnection(String url) async {
    final gas = GasClient(baseUrl: url, token: 'unused-for-health');
    try {
      return await gas.health();
    } finally {
      gas.close();
    }
  }

  AppSettings get settings {
    final s = _settings;
    if (s == null) throw StateError('JobStore belum di-init().');
    return s;
  }

  GasClient _requireGas() {
    final gas = _gas;
    if (gas == null) {
      throw StateError('GasClient belum tersedia: ${_missingConfig.join(', ')}');
    }
    return gas;
  }

  @override
  void dispose() {
    _gas?.close();
    super.dispose();
  }
}
