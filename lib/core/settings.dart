/// Penyimpanan konfigurasi aplikasi.
///
/// Nilai rahasia (API key, token GAS, isi CV) masuk `flutter_secure_storage`
/// yang terenkripsi; preferensi non-rahasia masuk `shared_preferences`.
/// Keduanya dibaca dari HP, tidak ada server.
library;

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Data yang disimpan terenkripsi.
enum Secret {
  gasToken('gas_token'),
  geminiApiKey('gemini_api_key'),
  jsearchApiKey('jsearch_api_key'),
  serpApiKey('serpapi_key'),
  cvText('cv_text');

  const Secret(this.storageKey);
  final String storageKey;
}

/// Preferensi pencarian loker yang dipakai aggregator.
class JobSearchPrefs {
  const JobSearchPrefs({
    this.categories = const [
      'Cybersecurity Intern',
      'IT Intern',
      'Software Engineer Intern',
    ],
    this.location = 'Indonesia',
    this.remoteOnly = false,
  });

  /// Kata kunci posisi. Tiap kategori jadi satu query terpisah ke aggregator.
  final List<String> categories;
  final String location;
  final bool remoteOnly;

  JobSearchPrefs copyWith({List<String>? categories, String? location, bool? remoteOnly}) {
    return JobSearchPrefs(
      categories: categories ?? this.categories,
      location: location ?? this.location,
      remoteOnly: remoteOnly ?? this.remoteOnly,
    );
  }
}

class AppSettings {
  AppSettings._(this._secure, this._prefs);

  static const _kGasUrl = 'gas_url';
  static const _kGeminiModel = 'gemini_model';
  static const _kCategories = 'job_categories';
  static const _kLocation = 'job_location';
  static const _kRemoteOnly = 'job_remote_only';
  static const _kDailyHour = 'daily_hour';
  static const _kLastRunDate = 'last_run_date';
  static const _kMinMatchScore = 'min_match_score';

  static const defaultGeminiModel = 'gemini-3.8-flash';
  static const defaultDailyHour = 12;

  final FlutterSecureStorage _secure;
  final SharedPreferences _prefs;

  static Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    // flutter_secure_storage v11 mengenkripsi secara default (RSA key wrapping + AES-GCM).
    return AppSettings._(const FlutterSecureStorage(), prefs);
  }

  /// Konstruktor untuk tes; memakai instance storage yang sudah disiapkan.
  static AppSettings forTesting(FlutterSecureStorage secure, SharedPreferences prefs) =>
      AppSettings._(secure, prefs);

  // ------------------------------------------------------------------ secrets

  Future<String?> secret(Secret key) => _secure.read(key: key.storageKey);

  /// [value] kosong atau null menghapus entri, supaya key lama tidak tertinggal.
  Future<void> setSecret(Secret key, String? value) {
    final v = value?.trim() ?? '';
    if (v.isEmpty) return _secure.delete(key: key.storageKey);
    return _secure.write(key: key.storageKey, value: v);
  }

  Future<Map<Secret, String?>> allSecrets() async {
    final out = <Secret, String?>{};
    for (final key in Secret.values) {
      out[key] = await _secure.read(key: key.storageKey);
    }
    return out;
  }

  String? get gasUrl => _emptyAsNull(_prefs.getString(_kGasUrl));
  Future<void> setGasUrl(String? url) => _setString(_kGasUrl, url);

  String get geminiModel => _emptyAsNull(_prefs.getString(_kGeminiModel)) ?? defaultGeminiModel;
  Future<void> setGeminiModel(String? model) => _setString(_kGeminiModel, model);

  int get dailyHour => (_prefs.getInt(_kDailyHour) ?? defaultDailyHour).clamp(0, 23);
  Future<void> setDailyHour(int hour) => _prefs.setInt(_kDailyHour, hour.clamp(0, 23));

  /// Skor minimum agar loker dianggap layak ditampilkan/dilamar.
  int get minMatchScore => _prefs.getInt(_kMinMatchScore) ?? 0;
  Future<void> setMinMatchScore(int score) => _prefs.setInt(_kMinMatchScore, score.clamp(0, 100));

  JobSearchPrefs get searchPrefs => JobSearchPrefs(
        categories: _prefs.getStringList(_kCategories)?.where((c) => c.trim().isNotEmpty).toList() ??
            const JobSearchPrefs().categories,
        location: _prefs.getString(_kLocation) ?? const JobSearchPrefs().location,
        remoteOnly: _prefs.getBool(_kRemoteOnly) ?? false,
      );

  Future<void> setSearchPrefs(JobSearchPrefs value) async {
    await _prefs.setStringList(_kCategories, value.categories);
    await _prefs.setString(_kLocation, value.location);
    await _prefs.setBool(_kRemoteOnly, value.remoteOnly);
  }

  /// Tanggal (yyyy-MM-dd) pipeline terakhir berhasil jalan, dipakai scheduler
  /// agar task tidak dieksekusi dua kali dalam sehari.
  String? get lastRunDate => _emptyAsNull(_prefs.getString(_kLastRunDate));
  Future<void> setLastRunDate(String date) => _prefs.setString(_kLastRunDate, date);

  /// Konfigurasi minimum supaya pipeline harian boleh jalan.
  Future<List<String>> missingRequirements() async {
    final missing = <String>[];
    if (gasUrl == null) missing.add('URL Google Apps Script');
    if ((await secret(Secret.gasToken)) == null) missing.add('API Token GAS');
    if ((await secret(Secret.geminiApiKey)) == null) missing.add('Gemini API Key');
    final hasJobSource = (await secret(Secret.jsearchApiKey)) != null ||
        (await secret(Secret.serpApiKey)) != null;
    if (!hasJobSource) missing.add('JSearch atau SerpAPI Key');
    if ((await secret(Secret.cvText)) == null) missing.add('Teks CV');
    return missing;
  }

  Future<bool> isReady() async => (await missingRequirements()).isEmpty;

  String? _emptyAsNull(String? value) {
    final v = value?.trim();
    return (v == null || v.isEmpty) ? null : v;
  }

  Future<void> _setString(String key, String? value) {
    final v = value?.trim() ?? '';
    return v.isEmpty ? _prefs.remove(key) : _prefs.setString(key, v);
  }
}
