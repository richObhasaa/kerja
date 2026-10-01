import 'package:flutter/material.dart';

import 'dashboard_page.dart';
import 'job_store.dart';

class AyoKerjaApp extends StatelessWidget {
  const AyoKerjaApp({required this.store, super.key});

  final JobStore store;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Auto Internship Finder',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF1B5E9E),
        visualDensity: VisualDensity.compact,
      ),
      home: DashboardPage(store: store),
    );
  }
}
