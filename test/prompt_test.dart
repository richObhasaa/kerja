import 'dart:io';

import 'package:auto_internship_finder/core/models.dart';
import 'package:auto_internship_finder/core/prompt.dart';
import 'package:auto_internship_finder/core/prompt_assets.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Input ini HARUS identik dengan yang dipakai menghasilkan
/// `test/fixtures/prompt_golden.txt` dari `src/prompt.ts` asli.
const _cvText =
    'Nama: Budi\nSkills: Wireshark, Linux, Python\nPendidikan: S1 Informatika';

const _job = JobPosting(
  title: 'Cybersecurity Intern',
  company: 'Telkom Indonesia',
  location: 'Jakarta (Hybrid)',
  description:
      'Mencari mahasiswa magang untuk tim SOC.\nWajib: Wireshark, Linux.\nNilai tambah: SIEM, Nmap.',
  jobUrl: 'https://linkedin.com/jobs/view/12345',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final template = File('assets/prompts/career_intelligence_engine.txt').readAsStringSync();
  final golden = File('test/fixtures/prompt_golden.txt').readAsStringSync();

  group('buildPrompt — fidelitas port dari src/prompt.ts', () {
    test('output byte-identik dengan golden dari versi TypeScript', () {
      final actual = buildPrompt(template, cvText: _cvText, job: _job);
      expect(actual, golden);
      expect(actual.length, golden.length, reason: 'panjang byte harus sama');
    });

    test('tidak ada placeholder yang tersisa', () {
      final actual = buildPrompt(template, cvText: _cvText, job: _job);
      expect(actual.contains('{{'), isFalse);
      expect(actual.contains('}}'), isFalse);
    });

    test('setiap field benar-benar masuk ke prompt', () {
      final actual = buildPrompt(template, cvText: _cvText, job: _job);
      expect(actual.contains('Wireshark, Linux, Python'), isTrue, reason: 'CV harus tersisip');
      expect(actual.contains('Cybersecurity Intern'), isTrue);
      expect(actual.contains('Telkom Indonesia'), isTrue);
      expect(actual.contains('Jakarta (Hybrid)'), isTrue);
      expect(actual.contains('tim SOC'), isTrue);
    });

    test('jobUrl tidak bocor ke prompt (template tidak punya placeholder-nya)', () {
      final actual = buildPrompt(template, cvText: _cvText, job: _job);
      expect(actual.contains('linkedin.com/jobs/view/12345'), isFalse);
    });

    test('nilai di-trim sebelum disisipkan, sama seperti versi TS', () {
      final padded = buildPrompt(
        template,
        cvText: '\n\n  $_cvText  \n\n',
        job: JobPosting(
          title: '  ${_job.title}  ',
          company: ' ${_job.company} ',
          location: '  ${_job.location} ',
          description: '\n${_job.description}\n',
          jobUrl: _job.jobUrl,
        ),
      );
      expect(padded, golden);
    });

    test('karakter \$ disisipkan literal, bukan sebagai pola replace', () {
      // JavaScript memperlakukan "$&" pada replacement sebagai "seluruh match".
      // Dart tidak, dan itu memang perilaku yang kita inginkan di sini.
      final out = buildPrompt('CV: {{CV_TEXT}}', cvText: r'gaji $& $$ `', job: _job);
      expect(out, r'CV: gaji $& $$ `');
    });
  });

  group('asset', () {
    test('template terdaftar di pubspec dan bisa dimuat lewat rootBundle', () async {
      final fromAsset = await loadPromptTemplate();
      expect(fromAsset, template);
    });

    test('loadPromptTemplate menerima bundle kustom', () async {
      final bundle = TestAssetBundle('TEMPLATE-STUB');
      expect(await loadPromptTemplate(bundle: bundle), 'TEMPLATE-STUB');
    });
  });

  group('models — round-trip JSON Gemini', () {
    test('CareerAnalysisResult parse dari payload Gemini', () {
      final result = CareerAnalysisResult.fromJson(const {
        'job_info': {
          'title': 'IT Intern',
          'company': 'Glints',
          'location': 'Remote',
        },
        'match_analysis': {
          'match_score': 88,
          'match_level': 'HIGH',
          'key_matching_skills': ['Wireshark', 'Linux'],
          'missing_requirements': ['SIEM'],
          'match_reason': 'Profil relevan.',
        },
        'application_materials': {
          'tailored_summary': 'Ringkasan.',
          'cover_letter': 'Surat.',
        },
      });

      expect(result.matchAnalysis.matchScore, 88);
      expect(result.matchAnalysis.matchLevel, MatchLevel.high);
      expect(result.matchAnalysis.keyMatchingSkills, ['Wireshark', 'Linux']);
      expect(result.applicationMaterials.coverLetter, 'Surat.');
      expect(result.jobInfo.company, 'Glints');
    });

    test('toJson menghasilkan kunci snake_case untuk GAS', () {
      const result = CareerAnalysisResult(
        jobInfo: JobInfo(title: 'a', company: 'b', location: 'c'),
        matchAnalysis: MatchAnalysis(
          matchScore: 91,
          matchLevel: MatchLevel.high,
          keyMatchingSkills: ['x'],
          missingRequirements: [],
          matchReason: 'r',
        ),
        applicationMaterials: ApplicationMaterials(tailoredSummary: 's', coverLetter: 'l'),
      );

      final json = result.toJson();
      expect(json.keys, ['job_info', 'match_analysis', 'application_materials']);
      final match = json['match_analysis']! as Map<String, dynamic>;
      expect(match.keys, [
        'match_score',
        'match_level',
        'key_matching_skills',
        'missing_requirements',
        'match_reason',
      ]);
      expect(match['match_level'], 'HIGH');
    });

    test('match_level fallback dihitung dari skor bila Gemini tidak mengirimnya', () {
      MatchAnalysis parse(Object? score) => MatchAnalysis.fromJson({'match_score': score});

      expect(parse(95).matchLevel, MatchLevel.high);
      expect(parse(80).matchLevel, MatchLevel.high);
      expect(parse(79).matchLevel, MatchLevel.medium);
      expect(parse(50).matchLevel, MatchLevel.medium);
      expect(parse(49).matchLevel, MatchLevel.low);
      expect(parse(null).matchLevel, MatchLevel.low);
    });

    test('skor di-clamp ke 0..100 dan string numerik diterima', () {
      expect(MatchAnalysis.fromJson({'match_score': 140}).matchScore, 100);
      expect(MatchAnalysis.fromJson({'match_score': -5}).matchScore, 0);
      expect(MatchAnalysis.fromJson({'match_score': '87.6'}).matchScore, 88);
      expect(MatchAnalysis.fromJson({'match_score': 'bukan angka'}).matchScore, 0);
    });

    test('payload Gemini yang cacat tidak melempar exception', () {
      final result = CareerAnalysisResult.fromJson(const {});
      expect(result.jobInfo.title, '');
      expect(result.matchAnalysis.matchScore, 0);
      expect(result.matchAnalysis.keyMatchingSkills, isEmpty);
      expect(result.applicationMaterials.coverLetter, '');
    });

    test('JobPosting menerima variasi nama field dari aggregator', () {
      final a = JobPosting.fromJson(const {
        'title': 't',
        'job_apply_link': 'https://x/1',
        'job_description': 'd',
      });
      expect(a.jobUrl, 'https://x/1');
      expect(a.description, 'd');

      final b = JobPosting.fromJson(const {'job_url': 'https://x/2', 'description': 'd2'});
      expect(b.jobUrl, 'https://x/2');
      expect(b.description, 'd2');
    });
  });
}

class TestAssetBundle extends CachingAssetBundle {
  TestAssetBundle(this._content);
  final String _content;

  @override
  Future<ByteData> load(String key) async {
    expect(key, promptAssetPath);
    return ByteData.view(Uint8List.fromList(_content.codeUnits).buffer);
  }
}
