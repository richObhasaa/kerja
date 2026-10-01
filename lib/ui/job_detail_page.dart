import 'package:flutter/material.dart';

import '../data/gas_client.dart';
import 'apply_page.dart';
import 'job_store.dart';

class JobDetailPage extends StatefulWidget {
  const JobDetailPage({required this.store, required this.jobId, super.key});

  final JobStore store;
  final String jobId;

  @override
  State<JobDetailPage> createState() => _JobDetailPageState();
}

class _JobDetailPageState extends State<JobDetailPage> {
  StoredJob? _job;
  String? _error;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final job = await widget.store.fetchDetail(widget.jobId);
      if (!mounted) return;
      setState(() {
        _job = job;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  Future<void> _apply() async {
    final job = _job;
    if (job == null) return;

    final applied = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => ApplyPage(job: job)),
    );

    if (applied == true) {
      await widget.store.markApplied(job);
      await _load();
    }
  }

  Future<void> _setStatus(JobStatus status) async {
    final job = _job;
    if (job == null) return;
    await widget.store.setStatus(job, status);
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Detail Lowongan')),
      body: _buildBody(),
      bottomNavigationBar: _job == null ? null : _buildActions(),
    );
  }

  Widget _buildBody() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)));
    }

    final job = _job!;
    final theme = Theme.of(context);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(job.title, style: theme.textTheme.titleLarge),
        const SizedBox(height: 4),
        Text(
          [job.company, job.location].where((p) => p.isNotEmpty).join(' • '),
          style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          children: [
            Chip(label: Text('Match ${job.matchScore}% (${job.matchLevel.wire})')),
            Chip(label: Text('Status: ${job.status.label}')),
          ],
        ),
        if (job.matchReason.isNotEmpty) ...[
          const SizedBox(height: 16),
          _Section(title: 'Alasan Kecocokan', child: Text(job.matchReason)),
        ],
        if (job.keyMatchingSkills.isNotEmpty)
          _Section(
            title: 'Skill yang Cocok',
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: job.keyMatchingSkills
                  .map((s) => Chip(
                        label: Text(s, style: const TextStyle(fontSize: 12)),
                        visualDensity: VisualDensity.compact,
                        backgroundColor: theme.colorScheme.secondaryContainer,
                      ))
                  .toList(),
            ),
          ),
        if (job.missingRequirements.isNotEmpty)
          _Section(
            title: 'Yang Masih Kurang',
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              children: job.missingRequirements
                  .map((s) => Chip(
                        label: Text(s, style: const TextStyle(fontSize: 12)),
                        visualDensity: VisualDensity.compact,
                        backgroundColor: theme.colorScheme.errorContainer,
                      ))
                  .toList(),
            ),
          ),
        if (job.tailoredSummary?.isNotEmpty == true)
          _Section(
            title: 'Ringkasan Profil (Tailored)',
            child: SelectableText(job.tailoredSummary!, style: theme.textTheme.bodyMedium),
          ),
        if (job.coverLetter?.isNotEmpty == true)
          _Section(
            title: 'Cover Letter (Tailored)',
            child: SelectableText(job.coverLetter!, style: theme.textTheme.bodyMedium),
          ),
        _Section(
          title: 'Link Lamaran',
          child: SelectableText(job.jobUrl, style: theme.textTheme.bodySmall),
        ),
      ],
    );
  }

  Widget _buildActions() {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
        child: Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () => _setStatus(
                  _job!.status == JobStatus.saved ? JobStatus.fresh : JobStatus.saved,
                ),
                icon: Icon(_job!.status == JobStatus.saved
                    ? Icons.bookmark_remove_outlined
                    : Icons.bookmark_add_outlined),
                label: Text(_job!.status == JobStatus.saved ? 'Batal Simpan' : 'Simpan'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              flex: 2,
              child: FilledButton.icon(
                onPressed: _job!.status == JobStatus.applied ? null : _apply,
                icon: const Icon(Icons.send_outlined),
                label: Text(_job!.status == JobStatus.applied ? 'Sudah Dilamar' : 'Tailor & Apply'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: Theme.of(context)
                  .textTheme
                  .titleSmall
                  ?.copyWith(fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          child,
        ],
      ),
    );
  }
}
