import 'dart:convert';

import 'package:auto_internship_finder/core/models.dart';
import 'package:auto_internship_finder/core/settings.dart';
import 'package:auto_internship_finder/data/gas_client.dart';
import 'package:auto_internship_finder/ui/app.dart';
import 'package:auto_internship_finder/ui/job_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _gasUrl = 'https://script.google.com/macros/s/TEST/exec';

const _fullSecrets = {
  'gas_token': 'TOKEN-OK',
  'gemini_api_key': 'AIza-TEST',
  'jsearch_api_key': 'rapid-TEST',
  'cv_text': 'Nama: Budi\nSkills: Wireshark',
};

http.Response _listJobs(List<Map<String, dynamic>> jobs) => http.Response(
      jsonEncode({
        'ok': true,
        'action': 'list_jobs',
        'data': {'total': jobs.length, 'offset': 0, 'returned': jobs.length, 'jobs': jobs},
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

Map<String, dynamic> _job(String id, String title, String company, int score, String status) => {
      'id': id,
      'title': title,
      'company': company,
      'location': 'Jakarta',
      'job_url': 'https://jobs.example/$id',
      'match_score': score,
      'match_level': score >= 80 ? 'HIGH' : 'MEDIUM',
      'status': status,
      'match_reason': 'Relevan.',
      'key_matching_skills': ['Wireshark'],
      'missing_requirements': [],
      'created_at': '2026-10-01 12:00:00',
      'updated_at': '2026-10-01 12:00:00',
    };

Future<AppSettings> buildSettings({Map<String, String> secrets = _fullSecrets}) async {
  FlutterSecureStorage.setMockInitialValues(Map<String, String>.from(secrets));
  SharedPreferences.setMockInitialValues({'gas_url': _gasUrl});
  return AppSettings.forTesting(
    const FlutterSecureStorage(),
    await SharedPreferences.getInstance(),
  );
}

Future<void> pumpApp(WidgetTester tester, JobStore store) async {
  await tester.pumpWidget(AyoKerjaApp(store: store));
  await tester.pumpAndSettle();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('dashboard dengan konfigurasi lengkap', () {
    testWidgets('menampilkan loker dari Google Sheets', (tester) async {
      final settings = await buildSettings();
      final client = MockClient((request) async {
        expect(jsonDecode(request.body)['action'], 'list_jobs');
        return _listJobs([
          _job('a', 'SOC Analyst Intern', 'Telkom', 91, 'NEW'),
          _job('b', 'IT Support Intern', 'Glints', 64, 'SAVED'),
        ]);
      });

      final store = JobStore(settings: settings, httpClient: client);
      await store.init();
      await pumpApp(tester, store);

      expect(find.text('SOC Analyst Intern'), findsOneWidget);
      expect(find.text('IT Support Intern'), findsOneWidget);
      expect(find.text('Telkom • Jakarta'), findsOneWidget);
      expect(find.text('91%'), findsOneWidget);
      expect(find.text('Lowongan Magang'), findsOneWidget);
    });

    testWidgets('tombol Pindai Sekarang tersedia', (tester) async {
      final settings = await buildSettings();
      final client = MockClient((request) async => _listJobs([]));
      final store = JobStore(settings: settings, httpClient: client);
      await store.init();
      await pumpApp(tester, store);

      expect(find.text('Pindai Sekarang'), findsOneWidget);
    });

    testWidgets('chip filter status bisa dipilih', (tester) async {
      final settings = await buildSettings();
      final actions = <String>[];
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        actions.add('${body['action']}:${body['status'] ?? '-'}');
        return _listJobs([_job('a', 'SOC Intern', 'Telkom', 91, 'NEW')]);
      });

      final store = JobStore(settings: settings, httpClient: client);
      await store.init();
      await pumpApp(tester, store);

      await tester.tap(find.text('Dilamar'));
      await tester.pumpAndSettle();

      expect(actions.last, 'list_jobs:APPLIED');
    });

    testWidgets('daftar kosong menampilkan ajakan memindai', (tester) async {
      final settings = await buildSettings();
      final client = MockClient((request) async => _listJobs([]));
      final store = JobStore(settings: settings, httpClient: client);
      await store.init();
      await pumpApp(tester, store);

      expect(find.text('Belum ada lowongan'), findsOneWidget);
      expect(find.textContaining('Pindai Sekarang'), findsWidgets);
    });

    testWidgets('error GAS ditampilkan, bukan layar kosong', (tester) async {
      final settings = await buildSettings();
      final client = MockClient((request) async => http.Response(
            jsonEncode({'ok': false, 'error': {'code': 'unauthorized', 'message': 'Token tidak valid.'}}),
            200,
          ));

      final store = JobStore(settings: settings, httpClient: client);
      await store.init();
      await pumpApp(tester, store);

      expect(find.text('Gagal memuat data'), findsOneWidget);
      expect(find.textContaining('Token tidak valid'), findsOneWidget);
      expect(find.text('Coba lagi'), findsOneWidget);
    });
  });

  group('dashboard tanpa konfigurasi', () {
    testWidgets('menuntut pengguna mengisi Settings', (tester) async {
      final settings = await buildSettings(secrets: const {'gas_token': 'TOKEN-OK'});
      final client = MockClient((request) async => _listJobs([]));

      final store = JobStore(settings: settings, httpClient: client);
      await store.init();
      await pumpApp(tester, store);

      expect(find.text('Konfigurasi belum lengkap'), findsOneWidget);
      expect(find.textContaining('Gemini API Key'), findsOneWidget);
      expect(find.text('Buka Settings'), findsOneWidget);
      // Tidak boleh ada satu pun request keluar sebelum konfigurasi lengkap.
      expect(store.jobs, isEmpty);
    });

    testWidgets('URL GAS hilang tanpa token tetap terdeteksi', (tester) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues({});
      final settings = AppSettings.forTesting(
        const FlutterSecureStorage(),
        await SharedPreferences.getInstance(),
      );

      final store = JobStore(settings: settings, httpClient: MockClient((_) async => _listJobs([])));
      await store.init();
      await pumpApp(tester, store);

      expect(store.isConfigured, isFalse);
      expect(find.text('Konfigurasi belum lengkap'), findsOneWidget);
    });
  });

  group('JobStore', () {
    test('refresh mengisi jobs dan membersihkan error', () async {
      final settings = await buildSettings();
      final client = MockClient(
        (request) async => _listJobs([_job('a', 'SOC Intern', 'Telkom', 91, 'NEW')]),
      );

      final store = JobStore(settings: settings, httpClient: client);
      await store.init();
      await store.refresh();

      expect(store.jobs.single.title, 'SOC Intern');
      expect(store.jobs.single.matchScore, 91);
      expect(store.error, isNull);
      expect(store.loading, isFalse);
    });

    test('init bisa dipanggil ulang setelah Settings berubah', () async {
      final settings = await buildSettings();
      final store = JobStore(
        settings: settings,
        httpClient: MockClient((_) async => _listJobs([])),
      );

      await store.init();
      expect(store.isConfigured, isTrue);

      // Pengguna menghapus token dari Settings.
      await settings.setSecret(Secret.gasToken, null);
      await store.init();

      expect(store.isConfigured, isFalse);
      expect(store.missingConfig, contains('API Token GAS'));
    });

    test('markApplied memanggil action yang benar', () async {
      final settings = await buildSettings();
      final actions = <String>[];
      final client = MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        actions.add((body['action'] ?? '').toString());
        if (body['action'] == 'list_jobs') return _listJobs([]);
        return http.Response(jsonEncode({'ok': true, 'action': body['action'], 'data': {}}), 200);
      });

      final store = JobStore(settings: settings, httpClient: client);
      await store.init();

      await store.markApplied(_stored('JOB-1'));

      expect(actions, contains('mark_applied'));
    });
  });
}

StoredJob _stored(String id) => StoredJob(
      id: id,
      title: 't',
      company: 'c',
      location: 'l',
      jobUrl: 'https://jobs.example/$id',
      matchScore: 0,
      matchLevel: MatchLevel.low,
      status: JobStatus.fresh,
    );
