import 'package:flutter/material.dart';

import '../data/gas_client.dart';
import '../pipeline/daily_pipeline.dart';
import 'job_detail_page.dart';
import 'job_store.dart';
import 'settings_page.dart';

class DashboardPage extends StatefulWidget {
  const DashboardPage({required this.store, super.key});

  final JobStore store;

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => widget.store.refresh());
  }

  JobStore get store => widget.store;

  Future<void> _openSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => SettingsPage(store: store)),
    );
    // API key / URL GAS mungkin berubah, jadi settings harus dibaca ulang.
    await store.init();
    await store.refresh();
  }

  Future<void> _runScan() async {
    if (!store.isConfigured) {
      await _openSettings();
      return;
    }

    _showSnack('Memindai lowongan baru...');
    PipelineReport report;
    try {
      report = await store.runPipelineNow();
    } catch (e) {
      if (mounted) _showSnack('Pemindaian gagal: $e');
      return;
    }

    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (_) => _ReportDialog(report: report),
    );
    await store.refresh();
  }

  void _showSnack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 3)));
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        return Scaffold(
          appBar: AppBar(
            title: const Text('Lowongan Magang'),
            actions: [
              IconButton(
                tooltip: 'Muat ulang',
                icon: const Icon(Icons.refresh),
                onPressed: store.loading ? null : store.refresh,
              ),
              IconButton(
                tooltip: 'Settings',
                icon: const Icon(Icons.settings_outlined),
                onPressed: _openSettings,
              ),
            ],
          ),
          body: Column(
            children: [
              _StatusFilter(store: store),
              Expanded(child: _buildBody()),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: store.loading ? null : _runScan,
            icon: const Icon(Icons.radar),
            label: const Text('Pindai Sekarang'),
          ),
        );
      },
    );
  }

  Widget _buildBody() {
    if (!store.isConfigured) {
      return _EmptyState(
        icon: Icons.tune,
        title: 'Konfigurasi belum lengkap',
        message: store.missingConfig.isEmpty
            ? 'Isi URL Google Apps Script dan API Token di Settings.'
            : 'Masih kurang: ${store.missingConfig.join(', ')}.',
        actionLabel: 'Buka Settings',
        onAction: _openSettings,
      );
    }

    if (store.loading && store.jobs.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    if (store.error != null) {
      return _EmptyState(
        icon: Icons.cloud_off,
        title: 'Gagal memuat data',
        message: store.error!,
        actionLabel: 'Coba lagi',
        onAction: store.refresh,
      );
    }

    if (store.jobs.isEmpty) {
      return _EmptyState(
        icon: Icons.inbox_outlined,
        title: 'Belum ada lowongan',
        message: 'Tekan "Pindai Sekarang" untuk mencari lowongan magang baru.',
      );
    }

    return RefreshIndicator(
      onRefresh: store.refresh,
      child: ListView.separated(
        padding: const EdgeInsets.only(bottom: 88),
        itemCount: store.jobs.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) => _JobTile(job: store.jobs[index], store: store),
      ),
    );
  }
}

class _StatusFilter extends StatelessWidget {
  const _StatusFilter({required this.store});

  final JobStore store;

  static const _filters = <JobStatus?>[
    null,
    JobStatus.fresh,
    JobStatus.saved,
    JobStatus.applied,
  ];

  static String _label(JobStatus? status) => status?.label ?? 'Semua';

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        itemCount: _filters.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final filter = _filters[index];
          return ChoiceChip(
            label: Text(_label(filter)),
            selected: store.statusFilter == filter,
            onSelected: (_) => store.setStatusFilter(filter),
          );
        },
      ),
    );
  }
}

class _JobTile extends StatelessWidget {
  const _JobTile({required this.job, required this.store});

  final StoredJob job;
  final JobStore store;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return ListTile(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(builder: (_) => JobDetailPage(store: store, jobId: job.id)),
      ),
      title: Text(job.title.isEmpty ? '(tanpa judul)' : job.title,
          maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        [job.company, job.location].where((p) => p.isNotEmpty).join(' • '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      trailing: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          _ScoreBadge(score: job.matchScore),
          const SizedBox(height: 4),
          Text(job.status.label,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant)),
        ],
      ),
    );
  }
}

class _ScoreBadge extends StatelessWidget {
  const _ScoreBadge({required this.score});

  final int score;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (background, foreground) = switch (score) {
      >= 80 => (scheme.primary, scheme.onPrimary),
      >= 50 => (scheme.tertiaryContainer, scheme.onTertiaryContainer),
      _ => (scheme.surfaceContainerHighest, scheme.onSurfaceVariant),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(10)),
      child: Text('$score%',
          style: TextStyle(
              fontSize: 12, fontWeight: FontWeight.bold, color: foreground)),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

  final IconData icon;
  final String title;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.all(32),
      children: [
        Icon(icon, size: 48, color: scheme.onSurfaceVariant),
        const SizedBox(height: 16),
        Text(title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 8),
        Text(message,
            textAlign: TextAlign.center,
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(color: scheme.onSurfaceVariant)),
        if (actionLabel != null && onAction != null) ...[
          const SizedBox(height: 20),
          Center(
            child: FilledButton(onPressed: onAction, child: Text(actionLabel!)),
          ),
        ],
      ],
    );
  }
}

class _ReportDialog extends StatelessWidget {
  const _ReportDialog({required this.report});

  final PipelineReport report;

  @override
  Widget build(BuildContext context) {
    final rows = <(String, String)>[
      ('Loker diambil', '${report.fetchedCount}'),
      ('Baru (belum pernah dilihat)', '${report.newCount}'),
      ('Dianalisis AI', '${report.analyzedCount}'),
      ('Tersimpan ke Sheets', '${report.savedCount}'),
      ('Durasi', '${(report.elapsed.inMilliseconds / 1000).toStringAsFixed(1)} dtk'),
    ];

    return AlertDialog(
      title: Text(report.succeeded ? 'Pemindaian selesai' : 'Pemindaian tidak jalan'),
      content: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (report.skippedReason != null) ...[
              Text(report.skippedReason!),
              const SizedBox(height: 12),
            ],
            ...rows.map((r) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: [
                      Expanded(child: Text(r.$1)),
                      Text(r.$2, style: const TextStyle(fontWeight: FontWeight.w600)),
                    ],
                  ),
                )),
            if (report.failures.isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('${report.failures.length} kegagalan:',
                  style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              ...report.failures.take(5).map(
                    (f) => Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text('• $f', style: Theme.of(context).textTheme.bodySmall),
                    ),
                  ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Tutup'),
        ),
      ],
    );
  }
}
