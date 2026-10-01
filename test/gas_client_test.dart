import 'dart:convert';

import 'package:auto_internship_finder/core/models.dart';
import 'package:auto_internship_finder/data/gas_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _gasUrl = 'https://script.google.com/macros/s/AKfycbxTEST/exec';
const _redirectUrl = 'https://script.googleusercontent.com/macros/echo?user_content_key=ABC123';
const _token = 'sekret-123';

http.Response _ok(String action, Map<String, dynamic> data) =>
    http.Response(jsonEncode({'ok': true, 'action': action, 'data': data}), 200,
        headers: {'content-type': 'application/json'});

Map<String, dynamic> _sentBody(http.Request request) =>
    jsonDecode(request.body) as Map<String, dynamic>;

void main() {
  group('validasi URL deployment', () {
    test('menolak URL yang tidak berakhiran /exec', () {
      expect(
        () => GasClient(baseUrl: 'https://script.google.com/macros/s/ABC', token: _token),
        throwsA(isA<GasException>().having((e) => e.code, 'code', 'bad_request')),
      );
    });

    test('menolak URL kosong', () {
      expect(
        () => GasClient(baseUrl: '   ', token: _token),
        throwsA(isA<GasException>()),
      );
    });

    test('menerima /exec dan /dev', () {
      expect(GasClient(baseUrl: _gasUrl, token: _token).baseUrl, _gasUrl);
      expect(
        GasClient(baseUrl: 'https://script.google.com/macros/s/X/dev', token: _token).baseUrl,
        'https://script.google.com/macros/s/X/dev',
      );
    });
  });

  group('redirect 302 — gotcha utama GAS', () {
    test('mengikuti 302: hop pertama POST berbody, hop kedua GET tanpa body', () async {
      final methods = <String>[];
      final bodies = <String>[];
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        methods.add(request.method);
        bodies.add(request.body);
        if (calls == 1) {
          expect(request.url.toString(), _gasUrl);
          return http.Response('', 302, headers: {'location': _redirectUrl});
        }
        expect(request.url.toString(), _redirectUrl, reason: 'harus lompat ke lokasi redirect');
        expect(request.followRedirects, isFalse, reason: 'redirect ditangani manual');
        return _ok('list_jobs', {'total': 0, 'offset': 0, 'jobs': []});
      });

      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);
      final result = await gas.listJobs();

      expect(calls, 2);
      expect(methods, ['POST', 'GET'],
          reason: 'echo GAS menyajikan hasil doPost lewat GET; POST ulang dibalas login');
      expect(bodies[0], isNotEmpty, reason: 'body JSON harus ikut di hop pertama');
      expect(bodies[1], isEmpty, reason: 'hop GET tidak boleh membawa body');
      expect(result.total, 0);
    });

    test('redirect 307 mempertahankan method POST dan body', () async {
      final methods = <String>[];
      final bodies = <String>[];
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        methods.add(request.method);
        bodies.add(request.body);
        if (calls == 1) {
          return http.Response('', 307, headers: {'location': _redirectUrl});
        }
        return _ok('list_jobs', {'total': 0, 'offset': 0, 'jobs': []});
      });

      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);
      await gas.listJobs();

      expect(methods, ['POST', 'POST'], reason: '307 wajib mempertahankan method');
      expect(bodies[1], isNotEmpty, reason: '307 wajib mempertahankan body');
    });

    test('mengikuti redirect berantai sampai respons final', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls <= 2) {
          return http.Response('', 302, headers: {'location': 'https://hop$calls.example/x'});
        }
        return _ok('health', {
          'service': 'auto-internship-finder-api',
          'spreadsheet_id': 'SHEET1',
          'token_configured': true,
          'time': '2026-10-01 12:00:00',
        });
      });

      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);
      final health = await gas.health();
      expect(calls, 3);
      expect(health.spreadsheetId, 'SHEET1');
    });

    test('mendeteksi redirect loop', () async {
      final client = MockClient(
        (request) async => http.Response('', 302, headers: {'location': _redirectUrl}),
      );
      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);

      await expectLater(
        gas.health(),
        throwsA(isA<GasException>().having((e) => e.code, 'code', 'redirect_loop')),
      );
    });

    test('berhenti setelah batas maksimum redirect', () async {
      var hop = 0;
      final client = MockClient((request) async {
        hop++;
        return http.Response('', 302, headers: {'location': 'https://h$hop.example/'});
      });
      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);

      await expectLater(
        gas.health(),
        throwsA(isA<GasException>().having((e) => e.code, 'code', 'redirect_limit')),
      );
      expect(hop, 6, reason: '1 percobaan awal + 5 redirect');
    });

    test('redirect tanpa header location dikembalikan apa adanya', () async {
      final client = MockClient((request) async => http.Response('', 302));
      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);

      await expectLater(
        gas.health(),
        throwsA(isA<GasException>().having((e) => e.code, 'code', 'empty_response')),
      );
    });
  });

  group('format request', () {
    test('Content-Type text/plain, bukan application/json', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return _ok('list_jobs', {'total': 0, 'offset': 0, 'jobs': []});
      });

      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);
      await gas.listJobs();

      expect(captured.headers['Content-Type'], 'text/plain; charset=utf-8');
    });

    test('token ikut di body, bukan header', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return _ok('list_jobs', {'total': 0, 'offset': 0, 'jobs': []});
      });

      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);
      await gas.listJobs();

      expect(_sentBody(captured)['token'], _token);
      expect(captured.headers.containsKey('Authorization'), isFalse);
    });

    test('health tidak mengirim token', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return _ok('health', {'service': 'x', 'token_configured': true});
      });

      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);
      await gas.health();

      expect(_sentBody(captured).containsKey('token'), isFalse);
      expect(_sentBody(captured)['action'], 'health');
    });
  });

  group('penanganan error', () {
    test('envelope ok:false jadi GasException dengan kode dari server', () async {
      final client = MockClient((request) async => http.Response(
            jsonEncode({'ok': false, 'error': {'code': 'unauthorized', 'message': 'Token tidak valid.'}}),
            200,
          ));
      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);

      await expectLater(
        gas.listJobs(),
        throwsA(isA<GasException>()
            .having((e) => e.code, 'code', 'unauthorized')
            .having((e) => e.message, 'message', 'Token tidak valid.')),
      );
    });

    test('body kosong -> empty_response', () async {
      final client = MockClient((request) async => http.Response('', 200));
      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);

      await expectLater(
        gas.listJobs(),
        throwsA(isA<GasException>().having((e) => e.code, 'code', 'empty_response')),
      );
    });

    test('balasan HTML (bukan JSON) -> not_json', () async {
      final client = MockClient(
        (request) async => http.Response('<html>Sign in - Google Accounts</html>', 200),
      );
      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);

      await expectLater(
        gas.listJobs(),
        throwsA(isA<GasException>().having((e) => e.code, 'code', 'not_json')),
      );
    });

    test('get_job tanpa field job -> internal_error', () async {
      final client = MockClient((request) async => _ok('get_job', {}));
      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);

      await expectLater(
        gas.getJob(id: 'JOB-1'),
        throwsA(isA<GasException>().having((e) => e.code, 'code', 'internal_error')),
      );
    });
  });

  group('filter_new', () {
    test('mengirim field yang dibutuhkan dan mem-parse hasilnya', () async {
      late Map<String, dynamic> body;
      final client = MockClient((request) async {
        body = _sentBody(request);
        return _ok('filter_new', {
          'received': 2,
          'new_count': 1,
          'duplicate_count': 1,
          'new_jobs': [
            {
              'title': 'IT Intern',
              'company': 'Glints',
              'location': 'Remote',
              'job_url': 'https://glints.com/id/opportunities/99999',
              'url_key': 'glints.com/id/opportunities/99999',
              'description': 'Deskripsi loker.',
            }
          ],
          'duplicates': [
            {
              'job_url': 'https://linkedin.com/jobs/view/12345',
              'reason': 'already_in_database',
              'existing_id': 'JOB-ABC',
              'existing_status': 'APPLIED',
            }
          ],
        });
      });

      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);
      final result = await gas.filterNew(const [
        JobPosting(
          title: 'IT Intern',
          company: 'Glints',
          location: 'Remote',
          description: 'Deskripsi loker.',
          jobUrl: 'https://glints.com/id/opportunities/99999',
        ),
        JobPosting(
          title: 'Cybersecurity Intern',
          company: 'Telkom',
          location: 'Jakarta',
          description: 'd',
          jobUrl: 'https://linkedin.com/jobs/view/12345',
        ),
      ]);

      expect(body['action'], 'filter_new');
      expect((body['jobs'] as List).length, 2);
      expect((body['jobs'] as List).first['job_url'], 'https://glints.com/id/opportunities/99999');

      expect(result.received, 2);
      expect(result.newCount, 1);
      expect(result.duplicateCount, 1);
      expect(result.newJobs.single.title, 'IT Intern');
      expect(result.newJobs.single.jobUrl, 'https://glints.com/id/opportunities/99999');
      expect(result.duplicates.single.reason, 'already_in_database');
      expect(result.duplicates.single.existingStatus, JobStatus.applied);
    });
  });

  group('save_analysis', () {
    test('job_url dikirim terpisah dari objek analysis', () async {
      late Map<String, dynamic> body;
      final client = MockClient((request) async {
        body = _sentBody(request);
        return _ok('save_analysis', {
          'saved': 1,
          'created_count': 1,
          'updated_count': 0,
          'created': [
            {'id': 'JOB-XYZ', 'job_url': 'https://x', 'status': 'NEW', 'match_score': 88}
          ],
          'updated': [],
        });
      });

      const analysis = CareerAnalysisResult(
        jobInfo: JobInfo(title: 'Cybersecurity Intern', company: 'Telkom', location: 'Jakarta'),
        matchAnalysis: MatchAnalysis(
          matchScore: 88,
          matchLevel: MatchLevel.high,
          keyMatchingSkills: ['Wireshark'],
          missingRequirements: ['SIEM'],
          matchReason: 'Relevan.',
        ),
        applicationMaterials:
            ApplicationMaterials(tailoredSummary: 'Ringkasan.', coverLetter: 'Surat.'),
      );

      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);
      final result = await gas.saveAnalysis(const [
        (
          posting: JobPosting(
            title: 'Cybersecurity Intern',
            company: 'Telkom',
            location: 'Jakarta',
            description: 'd',
            jobUrl: 'https://linkedin.com/jobs/view/12345?utm_source=x',
          ),
          analysis: analysis,
        ),
      ]);

      final sent = (body['jobs'] as List).single as Map<String, dynamic>;
      expect(sent['job_url'], 'https://linkedin.com/jobs/view/12345?utm_source=x',
          reason: 'URL asli harus utuh di level atas');
      expect(sent['analysis']['job_info']['title'], 'Cybersecurity Intern');
      expect(sent['analysis']['match_analysis']['match_score'], 88);
      expect(sent['analysis']['match_analysis']['match_level'], 'HIGH');
      expect(sent['analysis']['application_materials']['cover_letter'], 'Surat.');
      expect((sent['analysis'] as Map).containsKey('job_url'), isFalse,
          reason: 'job_info tidak boleh memuat URL');

      expect(result.saved, 1);
      expect(result.createdCount, 1);
      expect(result.createdIds, ['JOB-XYZ']);
    });
  });

  group('list_jobs & get_job', () {
    test('filter status diserialisasi jadi string dipisah koma', () async {
      late Map<String, dynamic> body;
      final client = MockClient((request) async {
        body = _sentBody(request);
        return _ok('list_jobs', {'total': 0, 'offset': 0, 'jobs': []});
      });

      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);
      await gas.listJobs(
        status: const [JobStatus.fresh, JobStatus.saved],
        excludeStatus: const [JobStatus.applied],
        minScore: 70,
        search: 'cyber',
        limit: 20,
        offset: 10,
      );

      expect(body['status'], 'NEW,SAVED');
      expect(body['exclude_status'], 'APPLIED');
      expect(body['min_score'], 70);
      expect(body['search'], 'cyber');
      expect(body['limit'], 20);
      expect(body['offset'], 10);
    });

    test('field opsional yang kosong tidak ikut dikirim', () async {
      late Map<String, dynamic> body;
      final client = MockClient((request) async {
        body = _sentBody(request);
        return _ok('list_jobs', {'total': 0, 'offset': 0, 'jobs': []});
      });

      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);
      await gas.listJobs();

      expect(body.containsKey('status'), isFalse);
      expect(body.containsKey('exclude_status'), isFalse);
      expect(body.containsKey('search'), isFalse);
      expect(body.containsKey('min_score'), isFalse);
    });

    test('StoredJob di-parse lengkap termasuk materi lamaran', () async {
      final client = MockClient((request) async => _ok('get_job', {
            'job': {
              'id': 'JOB-1',
              'title': 'IT Intern',
              'company': 'Glints',
              'location': 'Remote',
              'job_url': 'https://glints.com/1',
              'match_score': '91',
              'match_level': 'HIGH',
              'status': 'SAVED',
              'match_reason': 'Cocok.',
              'key_matching_skills': ['Linux', 'Python'],
              'missing_requirements': 'Docker | K8s',
              'created_at': '2026-10-01 12:00:00',
              'updated_at': '2026-10-01 12:05:00',
              'tailored_summary': 'Ringkasan.',
              'cover_letter': 'Surat lamaran.',
            }
          }));

      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);
      final job = await gas.getJob(id: 'JOB-1');

      expect(job.matchScore, 91, reason: 'skor berupa string harus dikonversi');
      expect(job.matchLevel, MatchLevel.high);
      expect(job.status, JobStatus.saved);
      expect(job.keyMatchingSkills, ['Linux', 'Python']);
      expect(job.missingRequirements, ['Docker', 'K8s'],
          reason: 'format teks " | " dari sheet harus dipecah');
      expect(job.coverLetter, 'Surat lamaran.');
    });

    test('match_level hilang dihitung dari skor', () async {
      final client = MockClient((request) async => _ok('list_jobs', {
            'total': 5,
            'offset': 0,
            'jobs': [
              {'id': 'a', 'match_score': 85, 'status': 'NEW'},
              {'id': 'b', 'match_score': 55, 'status': 'NEW'},
              {'id': 'c', 'match_score': 20, 'status': 'NEW'},
            ]
          }));

      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);
      final result = await gas.listJobs();

      expect(result.jobs[0].matchLevel, MatchLevel.high);
      expect(result.jobs[1].matchLevel, MatchLevel.medium);
      expect(result.jobs[2].matchLevel, MatchLevel.low);
      expect(result.jobs[0].tailoredSummary, isNull,
          reason: 'list_jobs memang tidak mengirim materi lamaran');
      expect(result.total, 5);
      expect(result.jobs.length, 3);
      expect(result.hasMore, isTrue, reason: 'masih ada 2 loker di halaman berikutnya');
    });

    test('status tak dikenal jatuh ke NEW, bukan crash', () async {
      final client = MockClient((request) async => _ok('list_jobs', {
            'total': 1,
            'offset': 0,
            'jobs': [
              {'id': 'a', 'status': 'DITERIMA'}
            ]
          }));
      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);
      final result = await gas.listJobs();
      expect(result.jobs.single.status, JobStatus.fresh);
    });
  });

  group('mark_applied', () {
    test('mengirim id dan summary', () async {
      late Map<String, dynamic> body;
      final client = MockClient((request) async {
        body = _sentBody(request);
        return _ok('mark_applied', {'id': 'JOB-1', 'status': 'APPLIED'});
      });

      final gas = GasClient(baseUrl: _gasUrl, token: _token, httpClient: client);
      await gas.markApplied(id: 'JOB-1', tailoredSummary: 'Ringkasan.');

      expect(body['action'], 'mark_applied');
      expect(body['id'], 'JOB-1');
      expect(body['tailored_summary'], 'Ringkasan.');
      expect(body.containsKey('job_url'), isFalse);
    });
  });
}
