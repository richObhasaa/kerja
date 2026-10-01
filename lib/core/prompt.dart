/// Port Dart dari `src/prompt.ts`.
///
/// Versi TS membaca template lewat `node:fs`, yang tidak tersedia di Android.
/// Template dimuat sebagai Flutter asset (lihat `prompt_assets.dart`), dan
/// [buildPrompt] dibuat murni (menerima template sebagai argumen) supaya bisa
/// dites tanpa binding maupun dipakai dari perkakas CLI Dart murni.
library;

import 'models.dart';

const String promptAssetPath = 'assets/prompts/career_intelligence_engine.txt';

/// Mengisi placeholder template dengan data CV dan lowongan.
///
/// Setiap nilai di-`trim()` sebelum disisipkan, sama seperti versi TS.
/// Penyisipan bersifat literal: karakter `$` pada CV atau deskripsi tidak
/// diinterpretasikan (berbeda dari `String.replaceAll` di JavaScript yang
/// memperlakukan `$&`, `$$`, dsb. sebagai pola khusus).
String buildPrompt(
  String template, {
  required String cvText,
  required JobPosting job,
}) {
  return template
      .replaceAll('{{CV_TEXT}}', cvText.trim())
      .replaceAll('{{JOB_TITLE}}', job.title.trim())
      .replaceAll('{{COMPANY_NAME}}', job.company.trim())
      .replaceAll('{{JOB_LOCATION}}', job.location.trim())
      .replaceAll('{{JOB_DESCRIPTION}}', job.description.trim());
}
