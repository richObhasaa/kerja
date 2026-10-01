import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../core/settings.dart';
import '../data/cv_reader.dart';
import '../data/gas_client.dart';
import '../pipeline/notifier.dart';
import '../pipeline/scheduler.dart';
import 'job_store.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({required this.store, super.key});

  final JobStore store;

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final _gasUrl = TextEditingController();
  final _gasToken = TextEditingController();
  final _geminiKey = TextEditingController();
  final _geminiModel = TextEditingController();
  final _jsearchKey = TextEditingController();
  final _serpKey = TextEditingController();
  final _cvText = TextEditingController();
  final _categories = TextEditingController();
  final _location = TextEditingController();

  bool _remoteOnly = false;
  bool _obscure = true;
  bool _loading = true;
  bool _saving = false;
  bool _scheduled = false;
  String? _connectionInfo;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    for (final c in [
      _gasUrl,
      _gasToken,
      _geminiKey,
      _geminiModel,
      _jsearchKey,
      _serpKey,
      _cvText,
      _categories,
      _location,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  AppSettings get settings => widget.store.settings;

  Future<void> _load() async {
    final s = settings;
    final prefs = s.searchPrefs;
    final secrets = await s.allSecrets();

    if (!mounted) return;
    setState(() {
      _gasUrl.text = s.gasUrl ?? '';
      _gasToken.text = secrets[Secret.gasToken] ?? '';
      _geminiKey.text = secrets[Secret.geminiApiKey] ?? '';
      _geminiModel.text = s.geminiModel;
      _jsearchKey.text = secrets[Secret.jsearchApiKey] ?? '';
      _serpKey.text = secrets[Secret.serpApiKey] ?? '';
      _cvText.text = secrets[Secret.cvText] ?? '';
      _categories.text = prefs.categories.join(', ');
      _location.text = prefs.location;
      _remoteOnly = prefs.remoteOnly;
      _loading = false;
    });

    final scheduled = await DailyScheduler.isRegistered().catchError((_) => false);
    if (mounted) setState(() => _scheduled = scheduled);
  }

  Future<void> _pickCvFile() async {
    final file = await FilePicker.pickFile(
      dialogTitle: 'Pilih file CV',
      type: FileType.custom,
      allowedExtensions: ['pdf', 'txt', 'md'],
    );
    if (file == null) return;

    try {
      final bytes = await file.readAsBytes();
      final text = CvReader.extract(bytes, filename: file.name);
      if (!mounted) return;
      setState(() => _cvText.text = text);
      _snack('CV "${file.name}" terbaca: ${text.length} karakter.');
    } on CvFormatException catch (e) {
      _snack(e.message);
    } catch (e) {
      _snack('File tidak bisa dibaca: $e');
    }
  }

  Future<void> _testConnection() async {
    final url = _gasUrl.text.trim();
    if (url.isEmpty) {
      _snack('Isi URL Google Apps Script lebih dulu.');
      return;
    }
    setState(() => _connectionInfo = 'Menguji...');
    try {
      final health = await widget.store.checkConnection(url);
      setState(() => _connectionInfo =
          'Terhubung. Spreadsheet: ${health.spreadsheetId} • token ${health.tokenConfigured ? 'aktif' : 'BELUM diisi'}');
    } on GasException catch (e) {
      setState(() => _connectionInfo = 'Gagal: ${e.message}');
    } catch (e) {
      setState(() => _connectionInfo = 'Gagal: $e');
    }
  }

  Future<void> _toggleSchedule(bool enabled) async {
    setState(() => _scheduled = enabled);
    try {
      if (enabled) {
        await DailyScheduler.register();
        await AppNotifier().requestPermission();
        _snack('Pemindaian harian dijadwalkan setelah pukul ${settings.dailyHour.toString().padLeft(2, '0')}:00.');
      } else {
        await DailyScheduler.cancel();
        _snack('Penjadwalan dimatikan.');
      }
    } catch (e) {
      if (mounted) setState(() => _scheduled = !enabled);
      _snack('Gagal mengubah jadwal: $e');
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final s = settings;

    await s.setGasUrl(_gasUrl.text);
    await s.setSecret(Secret.gasToken, _gasToken.text);
    await s.setSecret(Secret.geminiApiKey, _geminiKey.text);
    await s.setGeminiModel(_geminiModel.text);
    await s.setSecret(Secret.jsearchApiKey, _jsearchKey.text);
    await s.setSecret(Secret.serpApiKey, _serpKey.text);
    await s.setSecret(Secret.cvText, _cvText.text);
    await s.setSearchPrefs(JobSearchPrefs(
      categories: _categories.text
          .split(',')
          .map((c) => c.trim())
          .where((c) => c.isNotEmpty)
          .toList(),
      location: _location.text.trim(),
      remoteOnly: _remoteOnly,
    ));

    if (!mounted) return;
    setState(() => _saving = false);
    Navigator.of(context).pop();
  }

  void _snack(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 4)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
        actions: [
          TextButton(
            onPressed: _saving ? null : _save,
            child: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Text('Simpan'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                _Header('Koneksi Google Apps Script'),
                _Field(
                  controller: _gasUrl,
                  label: 'URL Web App (/exec)',
                  hint: 'https://script.google.com/macros/s/.../exec',
                  keyboardType: TextInputType.url,
                ),
                _Field(
                  controller: _gasToken,
                  label: 'API Token GAS',
                  hint: 'hasil generateApiToken() di Apps Script',
                  obscure: _obscure,
                ),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _testConnection,
                      icon: const Icon(Icons.wifi_tethering, size: 16),
                      label: const Text('Tes Koneksi'),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      tooltip: _obscure ? 'Tampilkan rahasia' : 'Sembunyikan rahasia',
                      icon: Icon(_obscure ? Icons.visibility : Icons.visibility_off, size: 18),
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ],
                ),
                if (_connectionInfo != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 4, bottom: 8),
                    child: Text(_connectionInfo!, style: Theme.of(context).textTheme.bodySmall),
                  ),

                _Header('AI (Gemini)'),
                _Field(
                  controller: _geminiKey,
                  label: 'Gemini API Key',
                  hint: 'AIza...',
                  obscure: _obscure,
                ),
                _Field(
                  controller: _geminiModel,
                  label: 'Model',
                  hint: AppSettings.defaultGeminiModel,
                ),

                _Header('Sumber Lowongan'),
                _Field(
                  controller: _jsearchKey,
                  label: 'RapidAPI JSearch Key',
                  hint: 'isi salah satu atau keduanya',
                  obscure: _obscure,
                ),
                _Field(
                  controller: _serpKey,
                  label: 'SerpAPI Key',
                  obscure: _obscure,
                ),

                _Header('CV Kamu'),
                _Field(
                  controller: _cvText,
                  label: 'Teks CV',
                  hint: 'Tempel isi CV, atau ambil dari file PDF/TXT',
                  maxLines: 8,
                ),
                Row(
                  children: [
                    OutlinedButton.icon(
                      onPressed: _pickCvFile,
                      icon: const Icon(Icons.upload_file, size: 16),
                      label: const Text('Ambil file PDF/TXT'),
                    ),
                    const SizedBox(width: 12),
                    Text('${_cvText.text.length} karakter',
                        style: Theme.of(context).textTheme.bodySmall),
                  ],
                ),

                _Header('Preferensi Pencarian'),
                _Field(
                  controller: _categories,
                  label: 'Kategori posisi (pisahkan koma)',
                  hint: 'Cybersecurity Intern, IT Intern',
                  maxLines: 2,
                ),
                _Field(controller: _location, label: 'Lokasi', hint: 'Indonesia'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Hanya lowongan remote'),
                  value: _remoteOnly,
                  onChanged: (v) => setState(() => _remoteOnly = v),
                ),
                ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Jam pemindaian harian'),
                  subtitle: Text(
                      'WorkManager menjalankan pemeriksaan tiap jam; pipeline hanya dieksekusi '
                      'sekali sehari setelah pukul ${settings.dailyHour.toString().padLeft(2, '0')}:00.'),
                  trailing: DropdownButton<int>(
                    value: settings.dailyHour,
                    items: List.generate(
                      24,
                      (h) => DropdownMenuItem(
                        value: h,
                        child: Text('${h.toString().padLeft(2, '0')}:00'),
                      ),
                    ),
                    onChanged: (h) async {
                      if (h == null) return;
                      await settings.setDailyHour(h);
                      if (mounted) setState(() {});
                    },
                  ),
                ),

                _Header('Penjadwalan'),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Aktifkan pemindaian otomatis'),
                  subtitle: Text(_scheduled ? 'Terjadwal' : 'Tidak terjadwal'),
                  value: _scheduled,
                  onChanged: _toggleSchedule,
                ),
              ],
            ),
    );
  }
}

class _Header extends StatelessWidget {
  const _Header(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 8),
      child: Text(
        text,
        style: Theme.of(context)
            .textTheme
            .titleSmall
            ?.copyWith(color: Theme.of(context).colorScheme.primary, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _Field extends StatelessWidget {
  const _Field({
    required this.controller,
    required this.label,
    this.hint,
    this.obscure = false,
    this.maxLines = 1,
    this.keyboardType,
  });

  final TextEditingController controller;
  final String label;
  final String? hint;
  final bool obscure;
  final int maxLines;
  final TextInputType? keyboardType;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextField(
        controller: controller,
        obscureText: obscure,
        maxLines: obscure ? 1 : maxLines,
        keyboardType: keyboardType,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }
}
