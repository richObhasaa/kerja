/// Notifikasi Android untuk laporan harian.
///
/// [init] wajib dipanggil di setiap isolate yang memakainya — termasuk
/// isolate background WorkManager, yang tidak mewarisi state isolate utama.
library;

import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'daily_pipeline.dart';

class AppNotifier {
  AppNotifier({FlutterLocalNotificationsPlugin? plugin})
      : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const String channelId = 'daily_job_report';
  static const String channelName = 'Laporan Harian';
  static const String channelDescription =
      'Pemberitahuan jumlah lowongan magang baru yang ditemukan setiap hari.';

  static const int dailyReportId = 1001;

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    await _plugin.initialize(
      settings: const InitializationSettings(android: androidSettings),
    );

    final android =
        _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    await android?.createNotificationChannel(
      const AndroidNotificationChannel(
        channelId,
        channelName,
        description: channelDescription,
        importance: Importance.high,
      ),
    );

    _initialized = true;
  }

  /// Android 13+ membutuhkan izin runtime untuk menampilkan notifikasi.
  Future<bool> requestPermission() async {
    await init();
    final android =
        _plugin.resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
    if (android == null) return true;
    return await android.requestNotificationsPermission() ?? false;
  }

  Future<void> showDailyReport(PipelineReport report) {
    return show(
      report.newCount > 0
          ? 'Ditemukan ${report.newCount} Lowongan Magang Baru Hari Ini!'
          : 'Laporan Harian Lowongan Magang',
      report.notificationBody,
      id: dailyReportId,
    );
  }

  Future<void> show(String title, String body, {int id = 0}) async {
    await init();
    await _plugin.show(
      id: id,
      title: title,
      body: body,
      notificationDetails: const NotificationDetails(
        android: AndroidNotificationDetails(
          channelId,
          channelName,
          channelDescription: channelDescription,
          importance: Importance.high,
          priority: Priority.high,
        ),
      ),
    );
  }
}
