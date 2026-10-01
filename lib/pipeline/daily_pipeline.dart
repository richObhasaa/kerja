/// Orkestrasi alur otomatisasi harian (Step 2-5 pada spesifikasi).
///
/// fetch loker -> filter_new (dedup di GAS) -> Gemini analysis -> save_analysis.
/// Tidak ada server: seluruh orkestrasi ini jalan di HP, dipicu WorkManager.
library;

import 'dart:math';

import '../core/models.dart';
import '../core/prompt.dart';
import '../core/prompt_assets.dart';
import '../core/settings.dart';
import '../data/gas_client.dart';
import '../data/gemini_client.dart';
import '../data/job_source.dart';

/// Kegagalan pada satu tahap atau satu loker.
class PipelineFailure {
  const PipelineFailure(this.stage, this.message, {this.jobTitle});

  /// `aggregate`, `filter_new`, `analyze`, `save_analysis`, `setup`.
  final String stage;
  final String message;
  final String? jobTitle;

  @override
  String toString() => jobTitle == null ? '$stage: $message' : '$stage [$jobTitle]: $message';
}

class PipelineReport {
  const PipelineReport({
    this.ran = false,
    this.skippedReason,
    this.fetchedCount = 0,
    this.newCount = 0,
    this.analyzedCount = 0,
    this.savedCount = 0,
    this.topMatchScore = 0,
    this.topJobTitle,
    this.failures = const [],
    this.elapsed = Duration.zero,
  });

  /// `false` bila pipeline tidak dieksekusi karena konfigurasi belum lengkap.
  final bool ran;
  final String? skippedReason;

  final int fetchedCount;
  final int newCount;
  final int analyzedCount;
  final int savedCount;

  final int topMatchScore;
  final String? topJobTitle;

  final List<PipelineFailure> failures;
  final Duration elapsed;

  bool get succeeded => ran && skippedReason == null;

  /// Loker yang gagal dianalisis TIDAK disimpan ke sheet, jadi besok akan
  /// muncul lagi sebagai "baru". Aman untuk dibiarkan.
  bool get hasFailures => failures.isNotEmpty;

  String get notificationBody {
    if (!ran) return skippedReason ?? 'Pipeline tidak berjalan.';
    if (newCount == 0) return 'Tidak ada lowongan magang baru hari ini.';
    final top = topJobTitle == null ? '' : ' Tertinggi: $topJobTitle ($topMatchScore%).';
    return 'Ditemukan $newCount lowongan magang baru hari ini! Siap diapply.$top';
  }
}

class DailyPipeline {
  DailyPipeline({
    required this.settings,
    required this.gas,
    required this.gemini,
    required this.aggregator,
    this.maxAnalyzePerRun = 20,
    this.concurrency = 3,
    this.limitPerQuery = 25,
  });

  /// Membangun klien dari API key yang tersimpan di HP.
  static Future<DailyPipeline> fromSettings(
    AppSettings settings, {
    int maxAnalyzePerRun = 20,
    int concurrency = 3,
  }) async {
    final gasUrl = settings.gasUrl;
    final gasToken = await settings.secret(Secret.gasToken);
    final geminiKey = await settings.secret(Secret.geminiApiKey);

    if (gasUrl == null || gasToken == null || geminiKey == null) {
      final missing = await settings.missingRequirements();
      throw PipelineConfigException(missing);
    }

    final sources = <JobSource>[];
    final jsearchKey = await settings.secret(Secret.jsearchApiKey);
    final serpKey = await settings.secret(Secret.serpApiKey);
    if (jsearchKey != null) sources.add(JSearchSource(apiKey: jsearchKey));
    if (serpKey != null) sources.add(SerpApiSource(apiKey: serpKey));

    return DailyPipeline(
      settings: settings,
      gas: GasClient(baseUrl: gasUrl, token: gasToken),
      gemini: GeminiClient(apiKey: geminiKey, model: settings.geminiModel),
      aggregator: JobAggregator(sources),
      maxAnalyzePerRun: maxAnalyzePerRun,
      concurrency: concurrency,
    );
  }

  final AppSettings settings;
  final GasClient gas;
  final GeminiClient gemini;
  final JobAggregator aggregator;

  /// Batas loker yang dianalisis per run, menjaga kuota Gemini gratis.
  final int maxAnalyzePerRun;

  /// Jumlah panggilan Gemini paralel. Terlalu tinggi memicu rate limit 429.
  final int concurrency;

  final int limitPerQuery;

  Future<PipelineReport> run() async {
    final started = DateTime.now();

    final missing = await settings.missingRequirements();
    if (missing.isNotEmpty) {
      return PipelineReport(
        skippedReason: 'Konfigurasi belum lengkap: ${missing.join(', ')}.',
        elapsed: DateTime.now().difference(started),
      );
    }

    final failures = <PipelineFailure>[];
    final cvText = await settings.secret(Secret.cvText);
    if (cvText == null || cvText.trim().isEmpty) {
      return PipelineReport(
        skippedReason: 'Teks CV belum diisi di Settings.',
        elapsed: DateTime.now().difference(started),
      );
    }

    // ---- Step 2: fetch
    final aggregate = await aggregator.fetch(settings.searchPrefs, limitPerQuery: limitPerQuery);
    for (final error in aggregate.errors) {
      failures.add(PipelineFailure('aggregate', error.message));
    }
    if (aggregate.jobs.isEmpty) {
      return PipelineReport(
        ran: true,
        failures: failures,
        elapsed: DateTime.now().difference(started),
        skippedReason: aggregate.allSourcesFailed ? 'Semua sumber loker gagal dihubungi.' : null,
      );
    }

    // ---- Step 3: dedup di server
    FilterNewResult filtered;
    try {
      filtered = await gas.filterNew(aggregate.jobs);
    } on GasException catch (e) {
      return PipelineReport(
        ran: true,
        failures: [...failures, PipelineFailure('filter_new', e.message)],
        fetchedCount: aggregate.jobs.length,
        elapsed: DateTime.now().difference(started),
      );
    }

    if (filtered.newJobs.isEmpty) {
      return PipelineReport(
        ran: true,
        fetchedCount: filtered.received,
        failures: failures,
        elapsed: DateTime.now().difference(started),
      );
    }

    // ---- Step 4: analisis AI, hanya untuk yang benar-benar baru
    // Sisa di atas batas sengaja TIDAK disimpan, supaya besok masih dianggap
    // baru oleh filter_new dan tetap bisa dianalisis.
    final batch = filtered.newJobs.take(maxAnalyzePerRun).toList();

    final template = await loadPromptTemplate();
    final entries = await _analyzeAll(batch, cvText, template, failures);

    if (entries.isEmpty) {
      return PipelineReport(
        ran: true,
        fetchedCount: filtered.received,
        newCount: filtered.newCount,
        failures: failures,
        elapsed: DateTime.now().difference(started),
      );
    }

    // ---- Step 5: simpan ke Google Sheets
    SaveAnalysisResult saved;
    try {
      saved = await gas.saveAnalysis(entries);
    } on GasException catch (e) {
      return PipelineReport(
        ran: true,
        fetchedCount: filtered.received,
        newCount: filtered.newCount,
        analyzedCount: entries.length,
        failures: [...failures, PipelineFailure('save_analysis', e.message)],
        elapsed: DateTime.now().difference(started),
      );
    }

    var topScore = 0;
    String? topTitle;
    for (final entry in entries) {
      final score = entry.analysis.matchAnalysis.matchScore;
      if (score > topScore) {
        topScore = score;
        topTitle = entry.posting.title;
      }
    }

    return PipelineReport(
      ran: true,
      fetchedCount: filtered.received,
      newCount: filtered.newCount,
      analyzedCount: entries.length,
      savedCount: saved.saved,
      topMatchScore: topScore,
      topJobTitle: topTitle,
      failures: failures,
      elapsed: DateTime.now().difference(started),
    );
  }

  /// Menganalisis dengan konkurensi terbatas. Satu loker yang gagal tidak
  /// menghentikan sisanya.
  Future<List<AnalysisEntry>> _analyzeAll(
    List<JobPosting> jobs,
    String cvText,
    String template,
    List<PipelineFailure> failures,
  ) async {
    final slots = List<AnalysisEntry?>.filled(jobs.length, null);
    var cursor = 0;

    Future<void> worker() async {
      while (true) {
        final index = cursor++;
        if (index >= jobs.length) return;
        final job = jobs[index];
        try {
          final result = await gemini.analyze(buildPrompt(template, cvText: cvText, job: job));
          slots[index] = (posting: job, analysis: result);
        } on GeminiException catch (e) {
          failures.add(PipelineFailure('analyze', e.message, jobTitle: job.title));
        } catch (e) {
          failures.add(PipelineFailure('analyze', e.toString(), jobTitle: job.title));
        }
      }
    }

    final workerCount = max(1, min(concurrency, jobs.length));
    await Future.wait(List.generate(workerCount, (_) => worker()));

    return slots.whereType<AnalysisEntry>().toList(growable: false);
  }

  void close() {
    gas.close();
    gemini.close();
  }
}

class PipelineConfigException implements Exception {
  PipelineConfigException(this.missing);

  final List<String> missing;

  @override
  String toString() => 'Konfigurasi belum lengkap: ${missing.join(', ')}';
}
