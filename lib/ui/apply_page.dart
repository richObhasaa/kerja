/// Semi-automated apply: WebView ke link loker + overlay untuk menyalin
/// materi lamaran hasil AI.
///
/// Overlay di sini adalah widget Flutter biasa di dalam `Stack`, BUKAN system
/// overlay (SYSTEM_ALERT_WINDOW). Itu bisa dilakukan karena WebView-nya milik
/// kita sendiri, bukan Custom Tabs — jadi tidak perlu izin khusus dan tidak
/// ada risiko ditolak OEM.
///
/// Submit tetap manual oleh pengguna, sesuai desain anti-bot pada spesifikasi.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../data/gas_client.dart';

/// Pilihan pengguna pada dialog konfirmasi keluar.
enum _ExitChoice { cancel, leave, applied }

class ApplyPage extends StatefulWidget {
  const ApplyPage({required this.job, super.key});

  final StoredJob job;

  @override
  State<ApplyPage> createState() => _ApplyPageState();
}

class _ApplyPageState extends State<ApplyPage> {
  late final WebViewController _controller;
  late final Uri? _uri;
  bool _loading = true;
  bool _overlayVisible = true;
  String? _loadError;
  bool _confirming = false;

  @override
  void initState() {
    super.initState();
    // URL loker berasal dari API pihak ketiga, jadi bisa saja cacat.
    final parsed = Uri.tryParse(widget.job.jobUrl);
    _uri = (parsed != null && (parsed.isScheme('http') || parsed.isScheme('https')))
        ? parsed
        : null;

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageStarted: (_) {
            if (mounted) setState(() => _loadError = null);
          },
          onPageFinished: (_) {
            if (mounted) setState(() => _loading = false);
          },
          onWebResourceError: (error) {
            if (!mounted) return;
            setState(() {
              _loading = false;
              _loadError = error.description;
            });
          },
        ),
      );

    if (_uri != null) {
      _controller.loadRequest(_uri);
    } else {
      _loading = false;
    }
  }

  Future<void> _copy(String label, String? text) async {
    if (text == null || text.trim().isEmpty) {
      _snack('$label belum tersedia untuk loker ini.');
      return;
    }
    await Clipboard.setData(ClipboardData(text: text));
    _snack('$label disalin. Tempel di form lamaran (tahan kolomnya lalu Paste).');
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 4)));
  }

  /// LinkedIn dan sebagian situs karier menolak login di dalam WebView.
  Future<void> _openExternal() async {
    final uri = _uri;
    if (uri == null) {
      _snack('Link loker ini tidak valid: ${widget.job.jobUrl}');
      return;
    }
    final opened = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!opened && mounted) {
      _snack('Tidak ada aplikasi yang bisa membuka link ini.');
    }
  }

  Future<void> _confirmApplied() async {
    if (_confirming) return;
    _confirming = true;

    final done = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Sudah submit lamarannya?'),
        content: const Text(
          'Tandai APPLIED hanya bila form benar-benar sudah kamu kirim. '
          'Link ini tidak akan muncul lagi di pemindaian harian berikutnya.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('Belum'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('Sudah, tandai APPLIED'),
          ),
        ],
      ),
    );

    _confirming = false;
    if (mounted) Navigator.of(context).pop(done ?? false);
  }

  Future<void> _onPop() async {
    if (_confirming) return;
    _confirming = true;

    final choice = await showDialog<_ExitChoice>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Keluar dari halaman lamaran?'),
        content: const Text('Kalau lamarannya sudah dikirim, tandai sebagai APPLIED.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(_ExitChoice.cancel),
            child: const Text('Batal'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(_ExitChoice.leave),
            child: const Text('Keluar saja'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(dialogContext).pop(_ExitChoice.applied),
            child: const Text('Sudah apply'),
          ),
        ],
      ),
    );

    _confirming = false;
    // Dialog yang ditutup tanpa memilih (null) dianggap batal.
    if (choice == null || choice == _ExitChoice.cancel) return;
    if (mounted) Navigator.of(context).pop(choice == _ExitChoice.applied);
  }

  @override
  Widget build(BuildContext context) {
    final job = widget.job;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _onPop();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(job.company.isEmpty ? job.title : job.company,
              maxLines: 1, overflow: TextOverflow.ellipsis),
          actions: [
            IconButton(
              tooltip: 'Muat ulang',
              icon: const Icon(Icons.refresh),
              onPressed: () => _controller.reload(),
            ),
            IconButton(
              tooltip: 'Buka di browser eksternal',
              icon: const Icon(Icons.open_in_browser),
              onPressed: _openExternal,
            ),
            IconButton(
              tooltip: _overlayVisible ? 'Sembunyikan panel salin' : 'Tampilkan panel salin',
              icon: Icon(_overlayVisible ? Icons.visibility_off : Icons.content_paste),
              onPressed: () => setState(() => _overlayVisible = !_overlayVisible),
            ),
          ],
        ),
        body: Stack(
          children: [
            if (_uri == null)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Icon(Icons.link_off, size: 40),
                      const SizedBox(height: 12),
                      Text('Link loker tidak valid',
                          style: Theme.of(context).textTheme.titleMedium),
                      const SizedBox(height: 8),
                      SelectableText(widget.job.jobUrl,
                          textAlign: TextAlign.center,
                          style: Theme.of(context).textTheme.bodySmall),
                    ],
                  ),
                ),
              )
            else
              WebViewWidget(controller: _controller),
            if (_loading) const LinearProgressIndicator(),
            if (_loadError != null) _LoadErrorBanner(message: _loadError!, onOpenExternal: _openExternal),
            if (_overlayVisible)
              Positioned(
                left: 12,
                right: 12,
                bottom: 16,
                child: _CopyOverlay(
                  onCopyCoverLetter: () => _copy('Cover Letter', job.coverLetter),
                  onCopySummary: () => _copy('Ringkasan Profil', job.tailoredSummary),
                  onApplied: _confirmApplied,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _CopyOverlay extends StatelessWidget {
  const _CopyOverlay({
    required this.onCopyCoverLetter,
    required this.onCopySummary,
    required this.onApplied,
  });

  final VoidCallback onCopyCoverLetter;
  final VoidCallback onCopySummary;
  final VoidCallback onApplied;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

    return Material(
      elevation: 8,
      borderRadius: BorderRadius.circular(16),
      color: scheme.surfaceContainerHigh,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _MiniButton(
                    icon: Icons.mail_outline,
                    label: 'Salin Cover Letter',
                    onPressed: onCopyCoverLetter,
                  ),
                  const SizedBox(height: 6),
                  _MiniButton(
                    icon: Icons.summarize_outlined,
                    label: 'Salin Ringkasan CV',
                    onPressed: onCopySummary,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            SizedBox(
              width: 96,
              child: FilledButton(
                style: FilledButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 18),
                ),
                onPressed: onApplied,
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.check_circle_outline, size: 20),
                    SizedBox(height: 4),
                    Text('Sudah Apply', textAlign: TextAlign.center, style: TextStyle(fontSize: 11)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MiniButton extends StatelessWidget {
  const _MiniButton({required this.icon, required this.label, required this.onPressed});

  final IconData icon;
  final String label;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        visualDensity: VisualDensity.compact,
        textStyle: const TextStyle(fontSize: 12),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: 16),
      label: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
    );
  }
}

class _LoadErrorBanner extends StatelessWidget {
  const _LoadErrorBanner({required this.message, required this.onOpenExternal});

  final String message;
  final VoidCallback onOpenExternal;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Positioned(
      left: 12,
      right: 12,
      top: 12,
      child: Material(
        color: scheme.errorContainer,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Halaman gagal dimuat',
                  style: TextStyle(
                      fontWeight: FontWeight.bold, color: scheme.onErrorContainer)),
              const SizedBox(height: 4),
              Text(
                '$message\n\nSitus seperti LinkedIn sering menolak login di dalam WebView. '
                'Coba buka di browser eksternal.',
                style: TextStyle(fontSize: 12, color: scheme.onErrorContainer),
              ),
              const SizedBox(height: 8),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton.icon(
                  onPressed: onOpenExternal,
                  icon: const Icon(Icons.open_in_browser, size: 16),
                  label: const Text('Buka di browser'),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
