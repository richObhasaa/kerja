import 'dart:convert';

import 'package:auto_internship_finder/core/models.dart';
import 'package:auto_internship_finder/core/settings.dart';
import 'package:auto_internship_finder/data/job_source.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json'},
    );

const _prefs = JobSearchPrefs(
  categories: ['Cybersecurity Intern'],
  location: 'Indonesia',
);

void main() {
  group('buildQuery', () {
    test('kategori + lokasi', () {
      expect(buildQuery('IT Intern', _prefs), 'IT Intern Indonesia');
    });

    test('remoteOnly menggantikan lokasi dengan Remote', () {
      const remote = JobSearchPrefs(categories: [], location: 'Indonesia', remoteOnly: true);
      expect(buildQuery('IT Intern', remote), 'IT Intern Remote');
    });

    test('lokasi kosong menghasilkan kategori saja', () {
      const noLoc = JobSearchPrefs(categories: [], location: '  ');
      expect(buildQuery('IT Intern', noLoc), 'IT Intern');
    });
  });

  group('JSearchSource', () {
    test('mem-parse data dan memetakan field', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return _json({
          'status': 'OK',
          'data': [
            {
              'job_title': 'Cybersecurity Intern',
              'employer_name': 'Telkom',
              'job_city': 'Jakarta',
              'job_country': 'Indonesia',
              'job_description': 'Deskripsi SOC.',
              'job_apply_link': 'https://linkedin.com/jobs/view/1',
              'job_publisher': 'LinkedIn',
            }
          ]
        });
      });

      final source = JSearchSource(apiKey: 'rapid-key', httpClient: client);
      final jobs = await source.search(query: 'Cybersecurity Intern Indonesia');

      expect(jobs.single.title, 'Cybersecurity Intern');
      expect(jobs.single.company, 'Telkom');
      expect(jobs.single.location, 'Jakarta, Indonesia');
      expect(jobs.single.jobUrl, 'https://linkedin.com/jobs/view/1');
      expect(jobs.single.source, 'JSearch');

      expect(captured.url.host, 'jsearch.p.rapidapi.com');
      expect(captured.url.path, '/search-v2');
      expect(captured.url.queryParameters['query'], 'Cybersecurity Intern Indonesia');
      expect(captured.url.queryParameters['date_posted'], 'month');
      expect(captured.headers['X-RapidAPI-Key'], 'rapid-key');
      expect(captured.headers['X-RapidAPI-Host'], 'jsearch.p.rapidapi.com');
    });

    test('nama field alternatif dari provider tetap terbaca', () async {
      final client = MockClient((request) async => _json({
            'status': 'OK',
            'data': [
              {
                'title': 'Data Intern',
                'company': 'Startup',
                'location': 'Bandung',
                'description': 'Desc.',
                'apply_link': 'https://x/alt',
              }
            ]
          }));

      final source = JSearchSource(apiKey: 'k', httpClient: client);
      final job = (await source.search(query: 'q')).single;

      expect(job.title, 'Data Intern');
      expect(job.company, 'Startup');
      expect(job.location, 'Bandung');
      expect(job.jobUrl, 'https://x/alt');
    });

    test('item tanpa field URL menjadi error terang, bukan nol sunyi', () async {
      final client = MockClient((request) async => _json({
            'status': 'OK',
            'data': [
              {'job_title': 'A'},
              {'job_title': 'B'},
            ]
          }));

      final source = JSearchSource(apiKey: 'k', httpClient: client);

      await expectLater(
        source.search(query: 'q'),
        throwsA(isA<JobSourceException>()
            .having((e) => e.message, 'message', contains('field URL'))),
      );
    });

    test('membuang entri tanpa job_apply_link', () async {
      final client = MockClient((request) async => _json({
            'status': 'OK',
            'data': [
              {'job_title': 'ada link', 'job_apply_link': 'https://x/1'},
              {'job_title': 'tanpa link'},
              {'job_title': 'link kosong', 'job_apply_link': '   '},
            ]
          }));

      final source = JSearchSource(apiKey: 'k', httpClient: client);
      final jobs = await source.search(query: 'q');

      expect(jobs.length, 1, reason: 'tanpa URL loker tidak bisa di-dedup maupun dilamar');
      expect(jobs.single.title, 'ada link');
    });

    test('menghormati limit', () async {
      final client = MockClient((request) async => _json({
            'status': 'OK',
            'data': List.generate(
              30,
              (i) => {'job_title': 'job $i', 'job_apply_link': 'https://x/$i'},
            ),
          }));

      final source = JSearchSource(apiKey: 'k', httpClient: client);
      expect((await source.search(query: 'q', limit: 5)).length, 5);
    });

    test('status selain OK jadi JobSourceException', () async {
      final client = MockClient(
        (request) async => _json({'status': 'ERROR', 'message': 'Invalid API key'}),
      );
      final source = JSearchSource(apiKey: 'k', httpClient: client);

      await expectLater(
        source.search(query: 'q'),
        throwsA(isA<JobSourceException>().having((e) => e.message, 'message', contains('Invalid API key'))),
      );
    });

    test('HTTP 403 karena key RapidAPI ditolak', () async {
      final client = MockClient(
        (request) async => _json({'message': 'You are not subscribed to this API.'}, 403),
      );
      final source = JSearchSource(apiKey: 'k', httpClient: client);

      await expectLater(source.search(query: 'q'), throwsA(isA<JobSourceException>()));
    });

    test('balasan bukan JSON (halaman HTML) tidak crash', () async {
      final client = MockClient((request) async => http.Response('<html>blocked</html>', 200));
      final source = JSearchSource(apiKey: 'k', httpClient: client);

      await expectLater(
        source.search(query: 'q'),
        throwsA(isA<JobSourceException>().having((e) => e.message, 'message', contains('bukan JSON'))),
      );
    });

    test('data kosong menghasilkan list kosong, bukan error', () async {
      final client = MockClient((request) async => _json({'status': 'OK', 'data': []}));
      final source = JSearchSource(apiKey: 'k', httpClient: client);

      expect(await source.search(query: 'q'), isEmpty);
    });

    test('API key kosong ditolak saat konstruksi', () {
      expect(() => JSearchSource(apiKey: ''), throwsA(isA<JobSourceException>()));
    });
  });

  group('SerpApiSource', () {
    test('mem-parse jobs_results', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return _json({
          'jobs_results': [
            {
              'title': 'Software Engineer Intern',
              'company_name': 'BCA',
              'location': 'Jakarta, Indonesia',
              'description': 'Kualifikasi...',
              'job_apply_link': 'https://jobstreet.co.id/job/555',
            }
          ]
        });
      });

      final source = SerpApiSource(apiKey: 'serp-key', httpClient: client);
      final jobs = await source.search(query: 'Software Engineer Intern');

      expect(jobs.single.title, 'Software Engineer Intern');
      expect(jobs.single.company, 'BCA');
      expect(jobs.single.jobUrl, 'https://jobstreet.co.id/job/555');
      expect(jobs.single.source, 'SerpAPI');

      expect(captured.url.host, 'serpapi.com');
      expect(captured.url.queryParameters['engine'], 'google_jobs');
      expect(captured.url.queryParameters['api_key'], 'serp-key');
      expect(captured.url.queryParameters['gl'], 'id');
    });

    test('membuang entri tanpa job_apply_link', () async {
      final client = MockClient((request) async => _json({
            'jobs_results': [
              {'title': 'punya link', 'job_apply_link': 'https://x/1'},
              {'title': 'tanpa link'},
            ]
          }));

      final source = SerpApiSource(apiKey: 'k', httpClient: client);
      expect((await source.search(query: 'q')).length, 1);
    });

    test('field error pada HTTP 200 dideteksi', () async {
      final client = MockClient(
        (request) async => _json({'error': "Google hasn't returned any results for this query."}),
      );
      final source = SerpApiSource(apiKey: 'k', httpClient: client);

      await expectLater(
        source.search(query: 'q'),
        throwsA(isA<JobSourceException>().having((e) => e.message, 'message', contains('returned any results'))),
      );
    });

    test('kuota habis (HTTP 429)', () async {
      final client = MockClient((request) async => _json({'error': 'Out of credits'}, 429));
      final source = SerpApiSource(apiKey: 'k', httpClient: client);

      await expectLater(
        source.search(query: 'q'),
        throwsA(isA<JobSourceException>().having((e) => e.message, 'message', contains('Out of credits'))),
      );
    });

    test('tidak ada jobs_results menghasilkan list kosong', () async {
      final client = MockClient((request) async => _json({'search_metadata': {'status': 'Success'}}));
      final source = SerpApiSource(apiKey: 'k', httpClient: client);

      expect(await source.search(query: 'q'), isEmpty);
    });
  });

  group('JobAggregator', () {
    test('menggabungkan hasil dari beberapa sumber dan kategori', () async {
      final aggregator = JobAggregator([
        _FakeSource('A', ['https://a/1', 'https://a/2']),
        _FakeSource('B', ['https://b/1']),
      ]);

      final result = await aggregator.fetch(
        const JobSearchPrefs(categories: ['Intern', 'Engineer'], location: 'Indonesia'),
      );

      // 2 sumber x 2 kategori; tiap query menghasilkan url sesuai sumbernya.
      expect(result.jobs, isNotEmpty);
      expect(result.errors, isEmpty);
      expect(result.countBySource.keys.toSet(), {'A', 'B'});
      expect(result.countBySource['A'], 4, reason: '2 kategori x 2 url');
      expect(result.countBySource['B'], 2);
    });

    test('sumber yang gagal tidak menggagalkan sumber lain', () async {
      final aggregator = JobAggregator([
        _FakeSource('Baik', ['https://ok/1']),
        _FailingSource('Rusak'),
      ]);

      final result = await aggregator.fetch(_prefs);

      expect(result.jobs.length, 1);
      expect(result.jobs.single.source, 'Baik');
      expect(result.errors.length, 1);
      expect(result.errors.single.source, 'Rusak');
      expect(result.allSourcesFailed, isFalse);
    });

    test('semua sumber gagal ditandai allSourcesFailed', () async {
      final aggregator = JobAggregator([_FailingSource('X'), _FailingSource('Y')]);
      final result = await aggregator.fetch(_prefs);

      expect(result.jobs, isEmpty);
      expect(result.errors.length, 2);
      expect(result.allSourcesFailed, isTrue);
    });

    test('exception non-JobSourceException tetap ditangkap', () async {
      final aggregator = JobAggregator([_ThrowingSource('Aneh')]);
      final result = await aggregator.fetch(_prefs);

      expect(result.errors.length, 1);
      expect(result.errors.single.source, 'Aneh');
    });

    test('kategori kosong dilewati', () async {
      final aggregator = JobAggregator([_FakeSource('A', ['https://a/1'])]);
      final result = await aggregator.fetch(
        const JobSearchPrefs(categories: ['', '   '], location: 'Indonesia'),
      );

      expect(result.jobs, isEmpty);
      expect(result.errors, isEmpty);
    });
  });
}

class _FakeSource implements JobSource {
  _FakeSource(this.name, this.urls);

  @override
  final String name;
  final List<String> urls;

  @override
  Future<List<JobPosting>> search({required String query, int limit = 25}) async {
    return urls
        .map((u) => JobPosting(
              title: '$name :: $query',
              company: name,
              location: 'Indonesia',
              description: 'd',
              jobUrl: u,
              source: name,
            ))
        .toList();
  }
}

class _FailingSource implements JobSource {
  _FailingSource(this.name);

  @override
  final String name;

  @override
  Future<List<JobPosting>> search({required String query, int limit = 25}) async {
    throw JobSourceException(name, 'API key tidak valid.');
  }
}

class _ThrowingSource implements JobSource {
  _ThrowingSource(this.name);

  @override
  final String name;

  @override
  Future<List<JobPosting>> search({required String query, int limit = 25}) async {
    throw StateError('kerusakan tak terduga');
  }
}
