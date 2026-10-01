// Diagnostik sekali pakai: membuktikan lapisan AI (template prompt + GeminiClient)
// bekerja terhadap Gemini API asli. Jalankan:
//   dart run tool/live_gemini_check.dart <GEMINI_API_KEY>
// ignore_for_file: avoid_print
import 'dart:io';

import 'package:auto_internship_finder/core/models.dart';
import 'package:auto_internship_finder/core/prompt.dart';
import 'package:auto_internship_finder/data/gemini_client.dart';

const _cv = '''
Nama: Budi Santoso.
Pendidikan: S1 Informatika, tingkat akhir.
Skill: Wireshark, Linux, Python, dasar jaringan, SQL.
Pengalaman: magang IT support 3 bulan; proyek analisis traffic jaringan kampus.
''';

const _job = JobPosting(
  title: 'Cybersecurity Intern',
  company: 'Contoh PT',
  location: 'Jakarta',
  description: 'Mencari mahasiswa magang untuk tim SOC. '
      'Wajib: Wireshark, Linux dasar. Nilai tambah: SIEM, Nmap, Python.',
  jobUrl: 'https://example.com/job/1',
);

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('pemakaian: dart run tool/live_gemini_check.dart <GEMINI_API_KEY>');
    return;
  }

  final template = File('assets/prompts/career_intelligence_engine.txt').readAsStringSync();
  final prompt = buildPrompt(template, cvText: _cv, job: _job);

  final gemini = GeminiClient(apiKey: args[0]);
  try {
    final result = await gemini.analyze(prompt);
    print('ANALISIS OK');
    print('  skor    : ${result.matchAnalysis.matchScore} (${result.matchAnalysis.matchLevel.wire})');
    print('  cocok   : ${result.matchAnalysis.keyMatchingSkills.join(', ')}');
    print('  kurang  : ${result.matchAnalysis.missingRequirements.join(', ')}');
    print('  alasan  : ${result.matchAnalysis.matchReason}');
    print('  summary : ${result.applicationMaterials.tailoredSummary}');
    final lines = result.applicationMaterials.coverLetter.split('\n');
    print('  surat   : ${lines.take(2).join(' / ')}');
  } catch (e) {
    print('ANALISIS GAGAL: $e');
  } finally {
    gemini.close();
  }
}
