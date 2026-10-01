import 'dart:convert';

import 'package:auto_internship_finder/core/models.dart';
import 'package:auto_internship_finder/data/gemini_client.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

const _validAnalysis = {
  'job_info': {
    'title': 'Cybersecurity Intern',
    'company': 'Telkom Indonesia',
    'location': 'Jakarta (Hybrid)',
  },
  'match_analysis': {
    'match_score': 88,
    'match_level': 'HIGH',
    'key_matching_skills': ['Wireshark', 'Linux'],
    'missing_requirements': ['SIEM'],
    'match_reason': 'Profil relevan dengan kebutuhan SOC.',
  },
  'application_materials': {
    'tailored_summary': 'Mahasiswa Informatika dengan pengalaman magang SOC.',
    'cover_letter': 'Yth. HRD Telkom,\n\nSaya tertarik...',
  },
};

http.Response _geminiOk(String text, {String finishReason = 'STOP'}) => http.Response(
      jsonEncode({
        'candidates': [
          {
            'content': {
              'role': 'model',
              'parts': [
                {'text': text}
              ],
            },
            'finishReason': finishReason,
          }
        ]
      }),
      200,
      headers: {'content-type': 'application/json'},
    );

void main() {
  group('parseJsonObject — balasan model yang bandel', () {
    test('JSON murni', () {
      final result = parseJsonObject(jsonEncode(_validAnalysis));
      expect(result['match_analysis']['match_score'], 88);
    });

    test('dibungkus markdown fence ```json', () {
      final wrapped = '```json\n${jsonEncode(_validAnalysis)}\n```';
      expect(parseJsonObject(wrapped)['job_info']['company'], 'Telkom Indonesia');
    });

    test('dibungkus markdown fence tanpa penanda bahasa', () {
      final wrapped = '```\n${jsonEncode(_validAnalysis)}\n```';
      expect(parseJsonObject(wrapped)['job_info']['company'], 'Telkom Indonesia');
    });

    test('ada kalimat pengantar dan penutup dari model', () {
      final noisy = 'Baik, berikut hasil analisisnya:\n'
          '${jsonEncode(_validAnalysis)}\n'
          'Semoga membantu!';
      expect(parseJsonObject(noisy)['match_analysis']['match_level'], 'HIGH');
    });

    test('kurung kurawal di dalam string tidak merusak pemindaian', () {
      const tricky = '{"application_materials":{"cover_letter":"Pakai format {nama} dan {posisi}."}}';
      final parsed = parseJsonObject(tricky);
      expect(parsed['application_materials']['cover_letter'], 'Pakai format {nama} dan {posisi}.');
    });

    test('tanda kutip ter-escape di dalam string tetap utuh', () {
      const tricky = r'{"match_analysis":{"match_reason":"Kata \"SOC\" cocok."}}';
      expect(parseJsonObject(tricky)['match_analysis']['match_reason'], 'Kata "SOC" cocok.');
    });

    test('newline di dalam string cover_letter', () {
      final parsed = parseJsonObject(jsonEncode(_validAnalysis));
      expect(
        (parsed['application_materials'] as Map)['cover_letter'],
        contains('\n'),
      );
    });

    test('array JSON di level atas bukan objek -> unparseable', () {
      expect(
        () => parseJsonObject('[1, 2, 3]'),
        throwsA(isA<GeminiException>().having((e) => e.code, 'code', 'unparseable')),
      );
    });

    test('teks tanpa JSON sama sekali -> unparseable', () {
      expect(
        () => parseJsonObject('Maaf, saya tidak bisa membantu.'),
        throwsA(isA<GeminiException>().having((e) => e.code, 'code', 'unparseable')),
      );
    });

    test('JSON cacat (kurung tidak tertutup) -> unparseable', () {
      expect(
        () => parseJsonObject('{"job_info": {"title": "x"'),
        throwsA(isA<GeminiException>().having((e) => e.code, 'code', 'unparseable')),
      );
    });

    test('string kosong -> empty_response', () {
      expect(
        () => parseJsonObject('   \n '),
        throwsA(isA<GeminiException>().having((e) => e.code, 'code', 'empty_response')),
      );
    });
  });

  group('generateText', () {
    test('mengambil teks dari candidates[0].content.parts', () async {
      final client = MockClient((request) async => _geminiOk('HALO'));
      final gemini = GeminiClient(apiKey: 'AIza-test', httpClient: client);

      expect(await gemini.generateText('prompt'), 'HALO');
    });

    test('part thoughts dari model reasoning tidak ikut digabung', () async {
      final client = MockClient((request) async => http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'mari saya pikirkan dulu {...bukan json...}', 'thought': true},
                      {'text': '{"jawab": 1}'}
                    ]
                  },
                  'finishReason': 'STOP'
                }
              ]
            }),
            200,
          ));
      final gemini = GeminiClient(apiKey: 'k', httpClient: client);

      expect(await gemini.generateText('p'), '{"jawab": 1}');
    });

    test('beberapa parts digabung', () async {
      final client = MockClient((request) async => http.Response(
            jsonEncode({
              'candidates': [
                {
                  'content': {
                    'parts': [
                      {'text': 'BA-'},
                      {'text': 'GIAN'}
                    ]
                  },
                  'finishReason': 'STOP'
                }
              ]
            }),
            200,
          ));
      final gemini = GeminiClient(apiKey: 'AIza-test', httpClient: client);

      expect(await gemini.generateText('p'), 'BA-GIAN');
    });

    test('API key dikirim lewat header, bukan query string', () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return _geminiOk('x');
      });
      final gemini = GeminiClient(apiKey: 'AIza-RAHASIA', httpClient: client);
      await gemini.generateText('p');

      expect(captured.headers['x-goog-api-key'], 'AIza-RAHASIA');
      expect(captured.url.queryParameters.containsKey('key'), isFalse,
          reason: 'key di URL akan bocor ke log proxy');
      expect(captured.url.toString(), isNot(contains('AIza')));
    });

    test('TIDAK mengirim responseMimeType (memicu 503) dan memakai model yang diminta',
        () async {
      late http.Request captured;
      final client = MockClient((request) async {
        captured = request;
        return _geminiOk('{}');
      });
      final gemini = GeminiClient(apiKey: 'k', model: 'gemini-1.5-flash', httpClient: client);
      await gemini.generateText('p');

      expect(captured.url.path, contains('gemini-1.5-flash:generateContent'));
      final body = jsonDecode(captured.body) as Map<String, dynamic>;
      final config = body['generationConfig'] as Map<String, dynamic>;
      expect(config.containsKey('responseMimeType'), isFalse,
          reason: 'mode structured-output dibalas 503 UNAVAILABLE pada gemini-3.8-flash');
      expect(config['temperature'], 0.3);
      expect(config['maxOutputTokens'], 8192);
      expect(body['contents'][0]['parts'][0]['text'], 'p');
    });

    test('503 transien dicoba ulang lalu pulih', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        if (calls == 1) {
          return http.Response(
            jsonEncode({
              'error': {'code': 503, 'message': 'high demand', 'status': 'UNAVAILABLE'}
            }),
            503,
          );
        }
        return _geminiOk('PULIH');
      });
      final gemini = GeminiClient(
        apiKey: 'k',
        httpClient: client,
        retryDelay: Duration.zero,
      );

      expect(await gemini.generateText('p'), 'PULIH');
      expect(calls, 2);
    });

    test('503 beruntun menyerah setelah batas percobaan', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response(
          jsonEncode({
            'error': {'code': 503, 'message': 'high demand', 'status': 'UNAVAILABLE'}
          }),
          503,
        );
      });
      final gemini = GeminiClient(
        apiKey: 'k',
        httpClient: client,
        retryDelay: Duration.zero,
      );

      await expectLater(
        gemini.generateText('p'),
        throwsA(isA<GeminiException>().having((e) => e.code, 'code', 'UNAVAILABLE')),
      );
      expect(calls, 3, reason: '1 percobaan awal + 2 ulang');
    });

    test('error non-transien tidak dicoba ulang', () async {
      var calls = 0;
      final client = MockClient((request) async {
        calls++;
        return http.Response(
          jsonEncode({
            'error': {'code': 400, 'message': 'API key not valid.', 'status': 'INVALID_ARGUMENT'}
          }),
          400,
        );
      });
      final gemini = GeminiClient(
        apiKey: 'k',
        httpClient: client,
        retryDelay: Duration.zero,
      );

      await expectLater(
        gemini.generateText('p'),
        throwsA(isA<GeminiException>().having((e) => e.code, 'code', 'INVALID_ARGUMENT')),
      );
      expect(calls, 1, reason: 'key salah tidak akan sembuh dengan retry');
    });

    test('HTTP 400 dengan detail error Gemini', () async {
      final client = MockClient((request) async => http.Response(
            jsonEncode({
              'error': {
                'code': 400,
                'message': 'API key not valid.',
                'status': 'INVALID_ARGUMENT',
              }
            }),
            400,
          ));
      final gemini = GeminiClient(apiKey: 'k', httpClient: client);

      await expectLater(
        gemini.generateText('p'),
        throwsA(isA<GeminiException>()
            .having((e) => e.code, 'code', 'INVALID_ARGUMENT')
            .having((e) => e.message, 'message', 'API key not valid.')),
      );
    });

    test('HTTP 429 kuota habis', () async {
      final client = MockClient((request) async => http.Response(
            jsonEncode({
              'error': {'code': 429, 'message': 'Quota exceeded.', 'status': 'RESOURCE_EXHAUSTED'}
            }),
            429,
          ));
      final gemini = GeminiClient(apiKey: 'k', httpClient: client);

      await expectLater(
        gemini.generateText('p'),
        throwsA(isA<GeminiException>().having((e) => e.code, 'code', 'RESOURCE_EXHAUSTED')),
      );
    });

    test('prompt diblokir filter keamanan', () async {
      final client = MockClient((request) async => http.Response(
            jsonEncode({'promptFeedback': {'blockReason': 'SAFETY'}}),
            200,
          ));
      final gemini = GeminiClient(apiKey: 'k', httpClient: client);

      await expectLater(
        gemini.generateText('p'),
        throwsA(isA<GeminiException>().having((e) => e.code, 'code', 'prompt_blocked')),
      );
    });

    test('finishReason SAFETY dengan teks kosong', () async {
      final client = MockClient((request) async => _geminiOk('', finishReason: 'SAFETY'));
      final gemini = GeminiClient(apiKey: 'k', httpClient: client);

      await expectLater(
        gemini.generateText('p'),
        throwsA(isA<GeminiException>()
            .having((e) => e.code, 'code', 'empty_response')
            .having((e) => e.message, 'message', contains('filter keamanan'))),
      );
    });

    test('tidak ada candidates', () async {
      final client = MockClient((request) async => http.Response(jsonEncode({'candidates': []}), 200));
      final gemini = GeminiClient(apiKey: 'k', httpClient: client);

      await expectLater(
        gemini.generateText('p'),
        throwsA(isA<GeminiException>().having((e) => e.code, 'code', 'no_candidate')),
      );
    });

    test('balasan bukan JSON', () async {
      final client = MockClient((request) async => http.Response('<html>502</html>', 502));
      final gemini = GeminiClient(apiKey: 'k', httpClient: client);

      await expectLater(
        gemini.generateText('p'),
        throwsA(isA<GeminiException>().having((e) => e.code, 'code', 'not_json')),
      );
    });

    test('API key kosong ditolak saat konstruksi', () {
      expect(
        () => GeminiClient(apiKey: '   '),
        throwsA(isA<GeminiException>().having((e) => e.code, 'code', 'bad_request')),
      );
    });
  });

  group('analyze — end to end', () {
    test('menghasilkan CareerAnalysisResult lengkap', () async {
      final client = MockClient(
        (request) async => _geminiOk('```json\n${jsonEncode(_validAnalysis)}\n```'),
      );
      final gemini = GeminiClient(apiKey: 'k', httpClient: client);

      final result = await gemini.analyze('prompt apa saja');

      expect(result.jobInfo.title, 'Cybersecurity Intern');
      expect(result.matchAnalysis.matchScore, 88);
      expect(result.matchAnalysis.matchLevel, MatchLevel.high);
      expect(result.matchAnalysis.keyMatchingSkills, ['Wireshark', 'Linux']);
      expect(result.matchAnalysis.missingRequirements, ['SIEM']);
      expect(result.applicationMaterials.coverLetter, startsWith('Yth. HRD Telkom'));
    });

    test('skor yang dikirim model sebagai string tetap diparse', () async {
      final match = Map<String, dynamic>.from(_validAnalysis['match_analysis'] as Map)
        ..['match_score'] = '92';
      final payload = Map<String, dynamic>.from(_validAnalysis)..['match_analysis'] = match;

      final client = MockClient((request) async => _geminiOk(jsonEncode(payload)));
      final gemini = GeminiClient(apiKey: 'k', httpClient: client);

      final result = await gemini.analyze('p');
      expect(result.matchAnalysis.matchScore, 92);
    });
  });
}
