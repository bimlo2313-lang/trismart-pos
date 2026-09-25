import 'package:flutter/material.dart';

import '../models/outlet.dart';
import '../services/backup_service.dart';
import '../services/restore_service.dart';
import '../services/restore_validation.dart';
import '../utils/transaction_date_format.dart';

class BackupSection extends StatefulWidget {
  const BackupSection({super.key, this.service, this.restoreService});
  final BackupService? service;
  final RestoreService? restoreService;

  @override
  State<BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends State<BackupSection> {
  late final _service = widget.service ?? BackupService();
  late final _restoreService = widget.restoreService ?? RestoreService();
  bool _restoring = false;
  bool _critical = false;
  Map<String, dynamic>? _last;
  bool _loading = true;
  bool _busy = false;
  bool _historyFailed = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final last = await _service.lastBackup();
      if (mounted) setState(() => _last = last);
    } catch (_) {
      if (mounted) setState(() => _historyFailed = true);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _backup() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final result = await _service.createBackup();
      if (!mounted || result == null) return;
      setState(() {
        _last = result.metadata;
        _historyFailed = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.historySaved
                ? 'Backup berhasil disimpan.'
                : 'Backup berhasil disimpan. Catatan backup terakhir gagal disimpan.',
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Backup gagal dibuat atau disimpan. Periksa ruang penyimpanan dan coba lagi.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _progress(String message) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => PopScope(
        canPop: false,
        child: AlertDialog(
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(message),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _restore() async {
    if (_busy || _restoring || _critical) return;
    setState(() => _restoring = true);
    ValidatedBackup? backup;
    var progress = false;
    final navigator = Navigator.of(context, rootNavigator: true);
    try {
      _progress('Membaca dan memvalidasi backup...');
      progress = true;
      backup = await _restoreService.prepare();
      navigator.pop();
      progress = false;
      if (!mounted || backup == null) return;
      final meta = backup.metadata;
      final code = meta['outlet_code'] as String?;
      final outlet = outletByCode(code);
      String count(Object? value) => value.toString().replaceAllMapped(
        RegExp(r'(\d)(?=(\d{3})+(?!\d))'),
        (m) => '${m[1]}.',
      );
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => PopScope(
          canPop: false,
          child: AlertDialog(
            scrollable: true,
            title: const Text('Backup TRISMART valid'),
            content: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Dibuat: ${formatTransactionDate(meta['created_at'] as String)}',
                ),
                Text(
                  'Asal: ${code == null ? 'Tidak tersedia' : '${outlet?.name ?? code} ($code)'}',
                ),
                Text('Terminal: ${meta['terminal_code'] ?? 'Tidak tersedia'}'),
                const Text('DB Version: 5'),
                Text('Produk: ${count(meta['product_count'])}'),
                Text('Transaksi: ${count(meta['transaction_count'])}'),
                const SizedBox(height: 16),
                const Text(
                  'Data database saat ini akan diganti dengan data dari backup ini.\nPengaturan outlet dan terminal perangkat ini tidak akan berubah.',
                ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('BATAL'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(dialogContext, true),
                child: const Text('PULIHKAN'),
              ),
            ],
          ),
        ),
      );
      if (!mounted || confirmed != true) return;
      _progress('Memulihkan data. Jangan tutup aplikasi...');
      progress = true;
      await _restoreService.restore(backup);
      navigator.pop();
      progress = false;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Data berhasil dipulihkan.')),
      );
      // Settings berasal dari Home; buang halaman database yang mungkin tertumpuk.
      // Home tidak menyimpan cache DB, setiap fitur berikutnya membuka helper terbaru.
      navigator.popUntil((route) => route.isFirst);
    } catch (error) {
      if (progress) {
        navigator.pop();
        progress = false;
      }
      if (!mounted) return;
      final message = error is RestoreException
          ? error.message
          : 'Pemulihan gagal. Silakan coba lagi.';
      if (error is RestoreException && error.critical) {
        setState(() => _critical = true);
        await showDialog<void>(
          context: context,
          barrierDismissible: false,
          builder: (_) => PopScope(
            canPop: false,
            child: AlertDialog(
              title: const Text('Pemulihan gagal — hubungi IT'),
              content: Text(message),
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(message)));
      }
    } finally {
      if (progress) navigator.pop();
      await backup?.dispose();
      if (mounted) setState(() => _restoring = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final code = _last?['outlet_code'] as String?;
    final terminal = _last?['terminal_code'] as String?;
    final origin = code == null || terminal == null
        ? 'Belum dikonfigurasi'
        : '${outletByCode(code)?.name ?? code} • $terminal';
    return Card(
      color: Colors.white,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Backup & Pemulihan Data',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.bold,
                color: Color(0xFF087F3E),
              ),
            ),
            const SizedBox(height: 16),
            const Text('Backup terakhir'),
            Text(
              _loading
                  ? 'Memuat...'
                  : _historyFailed
                  ? 'Catatan tidak dapat dimuat'
                  : _last == null
                  ? 'Belum pernah'
                  : formatTransactionDate(_last!['created_at'] as String),
            ),
            const SizedBox(height: 12),
            const Text('Asal'),
            Text(_last == null ? '—' : origin),
            const SizedBox(height: 12),
            const Text('Jumlah transaksi'),
            Text(_last == null ? '—' : '${_last!['transaction_count']}'),
            const SizedBox(height: 16),
            const Text(
              'Backup menyimpan database lokal aplikasi ke satu file .trismart.',
            ),
            const SizedBox(height: 12),
            if (_busy) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
            ],
            FilledButton(
              onPressed: _busy || _loading || _restoring || _critical
                  ? null
                  : _backup,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF087F3E),
              ),
              child: Text(
                _busy ? 'MEMBUAT BACKUP...' : 'BUAT BACKUP',
                textAlign: TextAlign.center,
              ),
            ),
            const SizedBox(height: 8),
            OutlinedButton(
              onPressed: _busy || _loading || _restoring || _critical
                  ? null
                  : _restore,
              child: const Text(
                'PULIHKAN DARI BACKUP',
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
