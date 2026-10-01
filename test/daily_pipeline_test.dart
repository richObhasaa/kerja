import 'dart:convert';

import 'package:auto_internship_finder/core/settings.dart';
import 'package:auto_internship_finder/data/gas_client.dart';
import 'package:auto_internship_finder/data/gemini_client.dart';
import 'package:auto_internship_finder/data/job_source.dart';
import 'package:auto_internship_finder/pipeline/daily_pipeline.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _gasUrl = 'https://script.google.com/macros/s/TEST/exec';

/// Meniru perilaku Google Sheets + Code.gs: simpan baris, dedup by URL.
class FakeGas {
  final Map<String, Map<String, dynamic>> rows = {};
  final List<String> actions = [];
  bool failOnSave = false;
  bool failOnFilter = false;

  http.Response handle(http.Request request) {
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final action = (body['action'] ?? '').toString();
    actions.add(action);

    if (body['token'] != 'TOKEN-OK') {
      return _err('unauthorized', 'Token tidak valid.');
    }

    switch (action) {
      case 'filter_new':
        if (failOnFilter) return _err('locked', 'Sedang sibuk.');
        final jobs = (body['jobs'] as List).cast<Map<String, dynamic>>();
        final fresh = <Map<String, dynamic>>[];
        final dups = <Map<String, dynamic>>[];
        for (final job in jobs) {
          final url = (job['job_url'] ?? '').toString();
          if (rows.containsKey(url)) {
            dups.add({'job_url': url, 'reason': 'already_in_database'});
          } else {
            fresh.add(job);
          }
        }
        return _ok('filter_new', {
          'received': jobs.length,
          'new_count': fresh.length,
          'duplicate_count': dups.length,
          'new_jobs': fresh,
          'duplicates': dups,
        });

      case 'save_analysis':
        if (failOnSave) return _err('locked', 'Sedang sibuk.');
        final jobs = (body['jobs'] as List).cast<Map<String, dynamic>>();
        var created = 0;
        for (final job in jobs) {
          rows[(job['job_url'] ?? '').toString()] = job;
          created++;
        }
        return _ok('save_analysis', {
          'saved': created,
          'created_count': created,
          'updated_count': 0,
          'created': jobs.map((j) => {'id': 'JOB-${j['job_url']}'}).toList(),
          'updated': [],
        });

      default:
        return _err('unknown_action', 'Action tidak dikenal: $action');
    }
  }
}

/// Membaca kembali field lowongan dari prompt, persis seperti Gemini
/// menyalinnya ke blok `job_info` pada skema output template.
String _promptField(String prompt, String label) {
  final m = RegExp('$label: (.*)').firstMatch(prompt);
  return m?.group(1)?.trim() ?? '';
}

class FakeGemini {
  int calls = 0;
  String? lastPrompt;

  http.Response handle(http.Request request) {
    calls++;
    final body = jsonDecode(request.body) as Map<String, dynamic>;
    final prompt =
        (((body['contents'] as List).first as Map)['parts'] as List).first['text'].toString();
    lastPrompt = prompt;

    final title = _promptField(prompt, r'\- Judul Posisi');
    final company = _promptField(prompt, r'\- Nama Perusahaan');
    final location = _promptField(prompt, r'\- Lokasi');

    if (prompt.contains('GAGALKAN')) {
      return http.Response(
        jsonEncode({
          'error': {'code': 429, 'message': 'Quota exceeded.', 'status': 'RESOURCE_EXHAUSTED'}
        }),
        429,
      );
    }

    final score = int.tryParse(RegExp(r'SKOR:(\d+)').firstMatch(prompt)?.group(1) ?? '50') ?? 50;

    return http.Response(
      jsonEncode({
        'candidates': [
          {
            'content': {
              'role': 'model',
              'parts': [
                {
                  'text': jsonEncode({
                    'job_info': {'title': title, 'company': company, 'location': location},
                    'match_analysis': {
                      'match_score': score,
                      'match_level': score >= 80 ? 'HIGH' : 'MEDIUM',
                      'key_matching_skills': ['Wireshark'],
                      'missing_requirements': [],
                      'match_reason': 'Relevan.',
                    },
                    'application_materials': {
                      'tailored_summary': 'Ringkasan $title.',
                      'cover_letter': 'Surat untuk $company.',
                    },
                  })
                }
              ]
            },
            'finishReason': 'STOP',
          }
        ]
      }),
      200,
    );
  }
}

http.Response _ok(String action, Map<String, dynamic> data) => http.Response(
      jsonEncode({'ok': true, 'action': action, 'data': data}),
      200,
      headers: {'content-type': 'application/json'},
    );

http.Response _err(String code, String message) => http.Response(
      jsonEncode({'ok': false, 'error': {'code': code, 'message': message}}),
      200,
      headers: {'content-type': 'application/json'},
    );

List<Map<String, dynamic>> _jsearchJobs(List<({String title, String desc})> specs) => specs
    .map((s) => {
          'job_title': s.title,
          'employer_name': 'PT ${s.title}',
          'job_city': 'Jakarta',
          'job_country': 'Indonesia',
          'job_description': s.desc,
          'job_apply_link': 'https://jobs.example/${Uri.encodeComponent(s.title)}',
        })
    .toList();

/// Satu MockClient untuk semua host, supaya wiring antar-klien ikut teruji.
MockClient buildClient({required FakeGas gas, required FakeGemini gemini, required List<Map<String, dynamic>> jsearch}) {
  return MockClient((request) async {
    switch (request.url.host) {
      case 'jsearch.p.rapidapi.com':
        return http.Response(
          jsonEncode({'status': 'OK', 'data': jsearch}),
          200,
          headers: {'content-type': 'application/json'},
        );
      case 'script.google.com':
      case 'script.googleusercontent.com':
        return gas.handle(request);
      case 'generativelanguage.googleapis.com':
        return gemini.handle(request);
      default:
        return http.Response('host tak terduga: ${request.url.host}', 500);
    }
  });
}

Future<AppSettings> buildSettings({
  Map<String, String> secrets = const {
    'gas_token': 'TOKEN-OK',
    'gemini_api_key': 'AIza-TEST',
    'jsearch_api_key': 'rapid-TEST',
    'cv_text': 'Nama: Budi\nSkills: Wireshark, Linux',
  },
  List<String> categories = const ['Cybersecurity Intern'],
}) async {
  FlutterSecureStorage.setMockInitialValues(Map<String, String>.from(secrets));
  SharedPreferences.setMockInitialValues({
    'gas_url': _gasUrl,
    'job_categories': categories,
    'job_location': 'Indonesia',
  });
  return AppSettings.forTesting(
    const FlutterSecureStorage(),
    await SharedPreferences.getInstance(),
  );
}

DailyPipeline buildPipeline(AppSettings settings, http.Client client, {int maxAnalyze = 20}) {
  return DailyPipeline(
    settings: settings,
    gas: GasClient(baseUrl: _gasUrl, token: 'TOKEN-OK', httpClient: client),
    gemini: GeminiClient(apiKey: 'AIza-TEST', httpClient: client),
    aggregator: JobAggregator([JSearchSource(apiKey: 'rapid-TEST', httpClient: client)]),
    maxAnalyzePerRun: maxAnalyze,
    concurrency: 2,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('pipeline berhenti sebelum memanggil API', () {
    test('konfigurasi belum lengkap -> skipped, tidak ada request', () async {
      final settings = await buildSettings(secrets: const {'gas_token': 'TOKEN-OK'});
      final gas = FakeGas();
      final gemini = FakeGemini();
      final pipeline = buildPipeline(
        settings,
        buildClient(gas: gas, gemini: gemini, jsearch: []),
      );

      final report = await pipeline.run();

      expect(report.ran, isFalse);
      expect(report.skippedReason, contains('belum lengkap'));
      expect(gas.actions, isEmpty);
      expect(gemini.calls, 0);
    });

    test('CV kosong -> skipped', () async {
      final settings = await buildSettings(secrets: const {
        'gas_token': 'TOKEN-OK',
        'gemini_api_key': 'AIza-TEST',
        'jsearch_api_key': 'rapid-TEST',
        'cv_text': '   ',
      });
      final gas = FakeGas();
      final pipeline = buildPipeline(
        settings,
        buildClient(gas: gas, gemini: FakeGemini(), jsearch: []),
      );

      final report = await pipeline.run();

      expect(report.ran, isFalse);
      expect(report.skippedReason, contains('CV'));
      expect(gas.actions, isEmpty);
    });
  });

  group('alur harian penuh (Step 2-5)', () {
    test('fetch -> filter_new -> Gemini -> save_analysis', () async {
      final settings = await buildSettings();
      final gas = FakeGas();
      final gemini = FakeGemini();
      final pipeline = buildPipeline(
        settings,
        buildClient(
          gas: gas,
          gemini: gemini,
          jsearch: _jsearchJobs(const [
            (title: 'SOC Intern', desc: 'SKOR:91 butuh Wireshark'),
            (title: 'IT Support Intern', desc: 'SKOR:64 helpdesk'),
          ]),
        ),
      );

      final report = await pipeline.run();

      expect(report.succeeded, isTrue, reason: report.failures.toString());
      expect(gas.actions, ['filter_new', 'save_analysis']);
      expect(report.fetchedCount, 2);
      expect(report.newCount, 2);
      expect(report.analyzedCount, 2);
      expect(report.savedCount, 2);
      expect(gemini.calls, 2);
      expect(gas.rows.length, 2);
      expect(report.topMatchScore, 91);
      expect(report.topJobTitle, 'SOC Intern');
      expect(report.notificationBody, contains('2 lowongan magang baru'));
    });

    test('CV pengguna benar-benar masuk ke prompt Gemini', () async {
      final settings = await buildSettings();
      final gas = FakeGas();
      final gemini = FakeGemini();

      await buildPipeline(
        settings,
        buildClient(gas: gas, gemini: gemini, jsearch: _jsearchJobs(const [
          (title: 'SOC Intern', desc: 'SKOR:80 x'),
        ])),
      ).run();

      final prompt = gemini.lastPrompt;
      expect(prompt, isNotNull);
      expect(prompt, contains('Wireshark, Linux'), reason: 'isi CV harus ada di prompt');
      expect(prompt, contains('SOC Intern'));
      expect(prompt, contains('Career Intelligence Engine'),
          reason: 'template asset harus termuat');
    });

    test('loker yang sudah ada di sheet TIDAK dianalisis ulang', () async {
      final settings = await buildSettings();
      final gas = FakeGas();
      final gemini = FakeGemini();
      final jobs = _jsearchJobs(const [
        (title: 'Lama', desc: 'SKOR:70 x'),
        (title: 'Baru', desc: 'SKOR:85 y'),
      ]);
      gas.rows['https://jobs.example/Lama'] = {'job_url': 'https://jobs.example/Lama'};

      final report = await buildPipeline(
        settings,
        buildClient(gas: gas, gemini: gemini, jsearch: jobs),
      ).run();

      expect(report.fetchedCount, 2);
      expect(report.newCount, 1);
      expect(gemini.calls, 1, reason: 'hanya loker baru yang boleh memakai kuota Gemini');
      expect(report.analyzedCount, 1);
    });

    test('tidak ada loker baru -> tidak memanggil Gemini maupun save', () async {
      final settings = await buildSettings();
      final gas = FakeGas();
      final gemini = FakeGemini();
      final jobs = _jsearchJobs(const [(title: 'Lama', desc: 'SKOR:70 x')]);
      gas.rows['https://jobs.example/Lama'] = {'job_url': 'https://jobs.example/Lama'};

      final report = await buildPipeline(
        settings,
        buildClient(gas: gas, gemini: gemini, jsearch: jobs),
      ).run();

      expect(report.ran, isTrue);
      expect(report.newCount, 0);
      expect(gemini.calls, 0);
      expect(gas.actions, ['filter_new']);
      expect(report.notificationBody, contains('Tidak ada lowongan magang baru'));
    });
  });

  group('ketahanan terhadap kegagalan', () {
    test('satu loker gagal dianalisis, sisanya tetap tersimpan', () async {
      final settings = await buildSettings();
      final gas = FakeGas();
      final gemini = FakeGemini();
      final report = await buildPipeline(
        settings,
        buildClient(
          gas: gas,
          gemini: gemini,
          jsearch: _jsearchJobs(const [
            (title: 'Rusak GAGALKAN', desc: 'SKOR:90 x'),
            (title: 'Sehat', desc: 'SKOR:77 y'),
          ]),
        ),
      ).run();

      expect(report.analyzedCount, 1);
      expect(report.savedCount, 1);
      expect(report.failures.length, 1);
      expect(report.failures.single.stage, 'analyze');
      expect(report.failures.single.jobTitle, contains('GAGALKAN'));
      expect(gas.rows.containsKey('https://jobs.example/Sehat'), isTrue);
      expect(gas.rows.containsKey('https://jobs.example/Rusak%20GAGALKAN'), isFalse,
          reason: 'yang gagal tidak boleh disimpan agar besok dicoba lagi');
    });

    test('maxAnalyzePerRun membatasi pemakaian kuota Gemini', () async {
      final settings = await buildSettings();
      final gas = FakeGas();
      final gemini = FakeGemini();
      final many = _jsearchJobs(
        List.generate(12, (i) => (title: 'Job$i', desc: 'SKOR:${50 + i} x')),
      );

      final report = await buildPipeline(
        settings,
        buildClient(gas: gas, gemini: gemini, jsearch: many),
        maxAnalyze: 3,
      ).run();

      expect(gemini.calls, 3);
      expect(report.analyzedCount, 3);
      expect(report.newCount, 12, reason: 'sisanya tetap dilaporkan baru');
      expect(report.savedCount, 3, reason: 'yang di luar batas tidak disimpan');
    });

    test('filter_new gagal -> pipeline berhenti tanpa memanggil Gemini', () async {
      final settings = await buildSettings();
      final gas = FakeGas()..failOnFilter = true;
      final gemini = FakeGemini();

      final report = await buildPipeline(
        settings,
        buildClient(gas: gas, gemini: gemini, jsearch: _jsearchJobs(const [
          (title: 'A', desc: 'SKOR:70 x'),
        ])),
      ).run();

      expect(report.ran, isTrue);
      expect(gemini.calls, 0);
      expect(report.failures.single.stage, 'filter_new');
      expect(report.savedCount, 0);
    });

    test('save_analysis gagal -> analisis tidak hilang sia-sia, error tercatat', () async {
      final settings = await buildSettings();
      final gas = FakeGas()..failOnSave = true;
      final gemini = FakeGemini();

      final report = await buildPipeline(
        settings,
        buildClient(gas: gas, gemini: gemini, jsearch: _jsearchJobs(const [
          (title: 'A', desc: 'SKOR:70 x'),
        ])),
      ).run();

      expect(gemini.calls, 1);
      expect(report.analyzedCount, 1);
      expect(report.savedCount, 0);
      expect(report.failures.single.stage, 'save_analysis');
    });

    test('semua sumber loker gagal -> dilaporkan, bukan dianggap sukses', () async {
      final settings = await buildSettings();
      final gas = FakeGas();
      final client = MockClient((request) async {
        if (request.url.host == 'jsearch.p.rapidapi.com') {
          return http.Response(jsonEncode({'status': 'ERROR', 'message': 'Invalid key'}), 200);
        }
        return gas.handle(request);
      });

      final report = await buildPipeline(settings, client).run();

      expect(report.ran, isTrue);
      expect(report.fetchedCount, 0);
      expect(report.skippedReason, contains('Semua sumber loker gagal'));
      expect(report.failures, isNotEmpty);
      expect(gas.actions, isEmpty, reason: 'tidak perlu memanggil GAS bila tidak ada data');
    });

    test('token GAS salah -> surfaced sebagai failure', () async {
      final settings = await buildSettings();
      final gas = FakeGas();
      final gemini = FakeGemini();
      final client = buildClient(
        gas: gas,
        gemini: gemini,
        jsearch: _jsearchJobs(const [(title: 'A', desc: 'SKOR:70 x')]),
      );

      final pipeline = DailyPipeline(
        settings: settings,
        gas: GasClient(baseUrl: _gasUrl, token: 'SALAH', httpClient: client),
        gemini: GeminiClient(apiKey: 'AIza-TEST', httpClient: client),
        aggregator: JobAggregator([JSearchSource(apiKey: 'rapid-TEST', httpClient: client)]),
      );

      final report = await pipeline.run();

      expect(report.failures.single.stage, 'filter_new');
      expect(report.failures.single.message, contains('Token tidak valid'));
      expect(gemini.calls, 0, reason: 'jangan bakar kuota Gemini bila dedup gagal');
      expect(gas.rows, isEmpty);
    });
  });

  group('CareerAnalysisResult tersimpan utuh', () {
    test('cover letter dan skor dari Gemini sampai ke payload save_analysis', () async {
      final settings = await buildSettings();
      final gas = FakeGas();
      final gemini = FakeGemini();

      await buildPipeline(
        settings,
        buildClient(gas: gas, gemini: gemini, jsearch: _jsearchJobs(const [
          (title: 'SOC Intern', desc: 'SKOR:91 butuh Wireshark'),
        ])),
      ).run();

      final saved = gas.rows.values.single;
      expect(saved['job_url'], 'https://jobs.example/SOC%20Intern');
      final analysis = saved['analysis'] as Map<String, dynamic>;
      expect(analysis['match_analysis']['match_score'], 91);
      expect(analysis['match_analysis']['match_level'], 'HIGH');
      expect(analysis['application_materials']['cover_letter'], 'Surat untuk PT SOC Intern.');
      expect(analysis['job_info']['title'], 'SOC Intern',
          reason: 'Gemini menyalin judul dari prompt template');
    });
  });
}
