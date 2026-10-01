import 'package:flutter/material.dart';
import 'package:workmanager/workmanager.dart';

import 'pipeline/scheduler.dart';
import 'ui/app.dart';
import 'ui/job_store.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Mendaftarkan dispatcher isolate background. Task periodiknya sendiri baru
  // dibuat saat pengguna mengaktifkannya di Settings, dan WorkManager
  // menyimpan pendaftaran itu lintas restart, jadi tidak perlu didaftar ulang.
  await Workmanager().initialize(backgroundDispatcher);

  final store = JobStore();
  await store.init();

  runApp(AyoKerjaApp(store: store));
}
