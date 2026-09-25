import 'package:flutter/material.dart';

import '../models/outlet.dart';
import '../services/settings_service.dart';
import 'backup_section.dart';

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  static const _green = Color(0xFF087F3E);
  final _service = SettingsService();
  final _form = GlobalKey<FormState>();
  String? _outletCode;
  String? _terminalCode;
  bool _loading = true;
  bool _saving = false;
  bool _loadFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _loadFailed = false;
    });
    try {
      final identity = await _service.load();
      if (!mounted) return;
      setState(() {
        _outletCode = identity?.outletCode;
        _terminalCode = identity?.terminalCode;
      });
    } catch (_) {
      if (mounted) setState(() => _loadFailed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      await _service.save(outletCode: _outletCode, terminalCode: _terminalCode);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Pengaturan berhasil disimpan.')),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Gagal menyimpan pengaturan. Silakan coba lagi.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF2F7F3),
    appBar: AppBar(title: const Text('Pengaturan'), foregroundColor: _green),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: _loading
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [
                    const Text(
                      'TRISMART',
                      style: TextStyle(
                        color: _green,
                        fontWeight: FontWeight.w900,
                        fontSize: 21,
                      ),
                    ),
                    const SizedBox(height: 16),
                    if (_loadFailed) ...[
                      const Text('Gagal memuat pengaturan.'),
                      TextButton(
                        onPressed: _load,
                        child: const Text('Coba lagi'),
                      ),
                    ] else
                      Card(
                        color: Colors.white,
                        child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Form(
                            key: _form,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Text(
                                  'Identitas Kasir',
                                  style: TextStyle(
                                    fontWeight: FontWeight.bold,
                                    fontSize: 20,
                                    color: _green,
                                  ),
                                ),
                                const SizedBox(height: 20),
                                DropdownButtonFormField<String>(
                                  key: const ValueKey('outlet'),
                                  initialValue: _outletCode,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Outlet',
                                    border: OutlineInputBorder(),
                                  ),
                                  hint: const Text('Pilih outlet'),
                                  items: [
                                    for (final outlet in outlets.where(
                                      (o) => o.active || o.code == _outletCode,
                                    ))
                                      DropdownMenuItem(
                                        value: outlet.code,
                                        enabled: outlet.active,
                                        child: Text(
                                          '${outlet.code} - ${outlet.name}${outlet.active ? '' : ' (Nonaktif)'}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                  ],
                                  onChanged: _saving
                                      ? null
                                      : (value) =>
                                            setState(() => _outletCode = value),
                                  validator: (value) =>
                                      outletByCode(value)?.active == true
                                      ? null
                                      : 'Pilih outlet aktif terlebih dahulu.',
                                ),
                                const SizedBox(height: 20),
                                DropdownButtonFormField<String>(
                                  key: const ValueKey('terminal'),
                                  initialValue: _terminalCode,
                                  isExpanded: true,
                                  decoration: const InputDecoration(
                                    labelText: 'Terminal',
                                    border: OutlineInputBorder(),
                                  ),
                                  hint: const Text('Pilih terminal'),
                                  items: [
                                    for (final code in terminalCodes)
                                      DropdownMenuItem(
                                        value: code,
                                        child: Text(code),
                                      ),
                                  ],
                                  onChanged: _saving
                                      ? null
                                      : (value) => setState(
                                          () => _terminalCode = value,
                                        ),
                                  validator: (value) =>
                                      terminalCodes.contains(value)
                                      ? null
                                      : 'Pilih terminal terlebih dahulu.',
                                ),
                                const SizedBox(height: 24),
                                const Text('Identitas Perangkat'),
                                const SizedBox(height: 6),
                                Text(
                                  _outletCode == null || _terminalCode == null
                                      ? 'Belum dipilih'
                                      : CashierIdentity(
                                          outletCode: _outletCode!,
                                          terminalCode: _terminalCode!,
                                        ).deviceIdentity,
                                  style: const TextStyle(
                                    fontSize: 22,
                                    fontWeight: FontWeight.bold,
                                    color: _green,
                                  ),
                                ),
                                const SizedBox(height: 24),
                                FilledButton(
                                  style: FilledButton.styleFrom(
                                    backgroundColor: _green,
                                  ),
                                  onPressed: _saving ? null : _save,
                                  child: Text(
                                    _saving
                                        ? 'MENYIMPAN...'
                                        : 'SIMPAN PENGATURAN',
                                    textAlign: TextAlign.center,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    const SizedBox(height: 16),
                    const BackupSection(),
                  ],
                ),
        ),
      ),
    ),
  );
}
