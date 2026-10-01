// Diagnostik sekali pakai: membuktikan GasClient (termasuk logika redirect)
// bekerja terhadap deployment GAS asli. Jalankan:
//   dart run tool/live_check.dart <URL_EXEC> [TOKEN]
// ignore_for_file: avoid_print
import 'package:auto_internship_finder/data/gas_client.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    print('pemakaian: dart run tool/live_check.dart <URL_EXEC> [TOKEN]');
    return;
  }
  final gas = GasClient(
    baseUrl: args[0],
    token: args.length > 1 ? args[1] : 'token-belum-diisi',
  );

  try {
    final h = await gas.health();
    print('HEALTH OK');
    print('  spreadsheet : ${h.spreadsheetId}');
    print('  token aktif : ${h.tokenConfigured}');
    print('  waktu server: ${h.time}');
  } catch (e) {
    print('HEALTH GAGAL: $e');
  }

  try {
    final r = await gas.listJobs(limit: 5);
    print('LIST_JOBS OK: total=${r.total}');
  } on GasException catch (e) {
    print('LIST_JOBS ditolak (${e.code}): ${e.message}');
  } catch (e) {
    print('LIST_JOBS GAGAL tak terduga: $e');
  }

  gas.close();
}
