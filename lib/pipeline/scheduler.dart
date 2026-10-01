/// Penjadwalan pemindaian harian dengan WorkManager.
///
/// WorkManager TIDAK bisa menjadwalkan task pada jam absolut — periodic work
/// hanya mengenal interval (minimum 15 menit) dan `initialDelay` yang bersifat
/// "tidak lebih cepat dari". Jadi "setiap hari pukul 12:00" diwujudkan sebagai
/// task periodik per jam yang mengecek sendiri apakah sudah lewat jam target
/// dan belum dijalankan hari ini.
library;

import 'package:workmanager/workmanager.dart';

import '../core/settings.dart';
import 'daily_pipeline.dart';
import 'notifier.dart';

const String dailyTaskName = 'dailyJobScan';
const String dailyTaskUniqueName = 'auto_internship_daily_scan';

/// Interval pemeriksaan. WorkManager menolak nilai di bawah 15 menit.
const Duration checkFrequency = Duration(hours: 1);

/// Keputusan murni "apakah pipeline perlu jalan sekarang?".
class RunDecision {
  const RunDecision.go(this.dateKey)
      : shouldRun = true,
        reason = 'Sudah lewat jam target dan belum dijalankan hari ini.';

  const RunDecision.skip(this.reason)
      : shouldRun = false,
        dateKey = null;

  final bool shouldRun;
  final String reason;

  /// Tanggal (yyyy-MM-dd) yang harus dicatat sebagai `lastRunDate`.
  final String? dateKey;
}

/// Kunci tanggal lokal, tanpa bergantung intl/timezone database.
String dateKey(DateTime date) =>
    '${date.year.toString().padLeft(4, '0')}-'
    '${date.month.toString().padLeft(2, '0')}-'
    '${date.day.toString().padLeft(2, '0')}';

RunDecision decideWhetherToRun({
  required DateTime now,
  required int dailyHour,
  required String? lastRunDate,
}) {
  final today = dateKey(now);
  if (lastRunDate == today) return const RunDecision.skip('Sudah dijalankan hari ini.');
  if (now.hour < dailyHour) {
    return RunDecision.skip('Belum lewat pukul ${dailyHour.toString().padLeft(2, '0')}:00.');
  }
  return RunDecision.go(today);
}

/// Menjalankan pipeline bila sudah waktunya. Dipanggil dari isolate background.
class DailyJobRunner {
  const DailyJobRunner();

  /// Mengembalikan `true` bila task dianggap selesai (termasuk saat dilewati).
  /// `false` memberi tahu WorkManager bahwa task gagal dan layak di-retry.
  Future<bool> runIfDue({DateTime? now, bool force = false}) async {
    final settings = await AppSettings.load();
    final notifier = AppNotifier();

    if (!force) {
      final decision = decideWhetherToRun(
        now: now ?? DateTime.now(),
        dailyHour: settings.dailyHour,
        lastRunDate: settings.lastRunDate,
      );
      if (!decision.shouldRun) return true;

      // Konfigurasi belum lengkap: JANGAN tandai sudah jalan, supaya setelah
      // pengguna mengisi Settings task hari itu masih bisa dieksekusi.
      if (!await settings.isReady()) return true;

      await settings.setLastRunDate(decision.dateKey!);
    }

    return _execute(settings, notifier);
  }

  Future<bool> _execute(AppSettings settings, AppNotifier notifier) async {
    DailyPipeline? pipeline;
    try {
      pipeline = await DailyPipeline.fromSettings(settings);
      final report = await pipeline.run();
      await notifier.showDailyReport(report);

      if (report.hasFailures) {
        await notifier.show(
          'Sebagian loker gagal diproses',
          '${report.failures.length} kegagalan. Pertama: ${report.failures.first}',
          id: AppNotifier.dailyReportId + 1,
        );
      }
      return true;
    } on PipelineConfigException catch (e) {
      await notifier.show('Pipeline belum bisa jalan', e.toString());
      // Konfigurasi salah tidak akan sembuh sendiri dengan retry.
      return true;
    } catch (e) {
      await notifier.show('Pemindaian harian gagal', e.toString());
      return false;
    } finally {
      pipeline?.close();
    }
  }
}

/// Entry point background. HARUS top-level dan ber-pragma `vm:entry-point`
/// agar tetap ada setelah tree-shaking release build.
@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((taskName, inputData) async {
    return const DailyJobRunner().runIfDue();
  });
}

class DailyScheduler {
  const DailyScheduler._();

  /// Mendaftarkan task periodik. Idempoten: `ExistingPeriodicWorkPolicy.keep`
  /// membuat pemanggilan ulang tidak mereset jadwal yang sudah berjalan.
  static Future<void> register() async {
    await Workmanager().initialize(backgroundDispatcher);
    await Workmanager().registerPeriodicTask(
      dailyTaskUniqueName,
      dailyTaskName,
      frequency: checkFrequency,
      initialDelay: const Duration(seconds: 15),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
      backoffPolicy: BackoffPolicy.exponential,
      backoffPolicyDelay: const Duration(minutes: 5),
    );
  }

  static Future<void> cancel() => Workmanager().cancelByUniqueName(dailyTaskUniqueName);

  static Future<bool> isRegistered() =>
      Workmanager().isScheduledByUniqueName(dailyTaskUniqueName);

  /// Tombol "Jalankan sekarang" di UI; melewati pengecekan jam.
  static Future<bool> runNow() => const DailyJobRunner().runIfDue(force: true);
}
