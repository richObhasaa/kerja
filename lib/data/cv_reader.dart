/// Ekstraksi teks CV dari file lokal HP.
///
/// Mendukung PDF dan teks polos. Kasus yang paling sering bikin gagal adalah
/// CV hasil scan (PDF berisi gambar tanpa lapisan teks) — itu dideteksi dan
/// dilaporkan sebagai error yang jelas, bukan string kosong yang diam-diam
/// membuat Gemini memberi skor 0.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:syncfusion_flutter_pdf/pdf.dart';

class CvFormatException implements Exception {
  CvFormatException(this.message);

  final String message;

  @override
  String toString() => 'CvFormatException: $message';
}

class CvReader {
  const CvReader._();

  /// Batas aman agar prompt tidak melebihi context window Gemini.
  /// CV normal 1-3 halaman jauh di bawah angka ini.
  static const int maxCharacters = 24000;

  static String extract(Uint8List bytes, {required String filename}) {
    if (bytes.isEmpty) {
      throw CvFormatException('File CV kosong.');
    }

    final text = filename.toLowerCase().endsWith('.pdf')
        ? _fromPdf(bytes)
        : _fromPlainText(bytes);

    final normalized = normalize(text);
    if (normalized.isEmpty) {
      throw CvFormatException(
        filename.toLowerCase().endsWith('.pdf')
            ? 'Tidak ada teks yang bisa dibaca dari PDF ini. '
                'Kemungkinan CV berupa hasil scan/gambar. '
                'Gunakan CV dengan teks, atau tempel isinya manual di Settings.'
            : 'File CV tidak berisi teks yang bisa dibaca.',
      );
    }
    return normalized;
  }

  static String _fromPdf(Uint8List bytes) {
    PdfDocument? document;
    try {
      document = PdfDocument(inputBytes: bytes);
      return PdfTextExtractor(document).extractText();
    } on CvFormatException {
      rethrow;
    } catch (e) {
      final message = e.toString().toLowerCase();
      if (message.contains('password') || message.contains('encrypt')) {
        throw CvFormatException('PDF CV diproteksi kata sandi. Buka proteksinya lebih dulu.');
      }
      throw CvFormatException('Gagal membaca PDF: $e');
    } finally {
      document?.dispose();
    }
  }

  static String _fromPlainText(Uint8List bytes) {
    try {
      return utf8.decode(bytes);
    } on FormatException {
      // File .txt hasil export Windows kadang memakai UTF-16 atau Latin-1.
      try {
        return String.fromCharCodes(bytes);
      } catch (_) {
        throw CvFormatException('Encoding file teks tidak dikenali.');
      }
    }
  }

  /// Merapikan whitespace dan memotong ke [maxCharacters].
  static String normalize(String text) {
    final collapsed = text
        .replaceAll('\r\n', '\n')
        .replaceAll(RegExp(r'[ \t]+'), ' ')
        .replaceAll(RegExp(r'\n{3,}'), '\n\n')
        .trim();

    if (collapsed.length <= maxCharacters) return collapsed;
    // Potong di batas kata, jangan di tengah, supaya tidak membingungkan model.
    final cut = collapsed.substring(0, maxCharacters);
    final lastSpace = cut.lastIndexOf(' ');
    return (lastSpace > maxCharacters - 400 ? cut.substring(0, lastSpace) : cut).trim();
  }
}
