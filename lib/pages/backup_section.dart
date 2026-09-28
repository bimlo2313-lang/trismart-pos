import 'dart:io' show Platform;

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../models/outlet.dart';
import '../services/backup_service.dart';
import '../services/data_transfer_lock.dart';
import '../services/restore_service.dart';
import '../services/restore_validation.dart';
import '../services/transaction_export_service.dart';
import '../utils/transaction_date_format.dart';

// Export period presets
enum ExportPeriod { today, yesterday, last7Days, thisMonth, custom }

class BackupSection extends StatefulWidget {
  const BackupSection({
    super.key,
    this.service,
    this.restoreService,
    this.exportService,
    this.saveExport,
    this.now,
  });
  final BackupService? service;
  final RestoreService? restoreService;
  final TransactionExportService? exportService;
  final Future<bool> Function(TransactionExportResult)? saveExport;
  final DateTime Function()? now;

  @override
  State<BackupSection> createState() => _BackupSectionState();
}

class _BackupSectionState extends State<BackupSection> {
  late final _service = widget.service ?? BackupService();
  late final _restoreService = widget.restoreService ?? RestoreService();
  late final _exportService =
      widget.exportService ?? TransactionExportService();
  DateTime _now() => (widget.now ?? DateTime.now)();
  bool _restoring = false;
  bool _critical = false;
  bool _exporting = false;
  Map<String, dynamic>? _last;
  bool _loading = true;
  bool _busy = false;
  bool _historyFailed = false;

  // Export period selection
  ExportPeriod _selectedPeriod = ExportPeriod.today;
  DateTime? _customStartDate;
  DateTime? _customEndDate;

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

  // Export period enum
  static const _periodLabels = {
    ExportPeriod.today: 'Hari Ini',
    ExportPeriod.yesterday: 'Kemarin',
    ExportPeriod.last7Days: '7 Hari Terakhir',
    ExportPeriod.thisMonth: 'Bulan Ini',
    ExportPeriod.custom: 'Pilih Tanggal',
  };

  // Calculate period boundaries based on local dates
  ({DateTime start, DateTime end}) _calculatePeriod(ExportPeriod period) {
    final now = _now();
    final today = DateTime(now.year, now.month, now.day);
    switch (period) {
      case ExportPeriod.today:
        return (start: today, end: today);
      case ExportPeriod.yesterday:
        final yesterday = today.subtract(const Duration(days: 1));
        return (start: yesterday, end: yesterday);
      case ExportPeriod.last7Days:
        return (start: today.subtract(const Duration(days: 6)), end: today);
      case ExportPeriod.thisMonth:
        return (start: DateTime(today.year, today.month, 1), end: today);
      case ExportPeriod.custom:
        return (start: _customStartDate ?? today, end: _customEndDate ?? today);
    }
  }

  // Validate custom date range
  String? _validateCustomRange() {
    if (_selectedPeriod != ExportPeriod.custom) return null;
    if (_customStartDate == null || _customEndDate == null) {
      return 'Pilih tanggal mulai dan tanggal akhir.';
    }
    if (_customEndDate!.isBefore(_customStartDate!)) {
      return 'Tanggal akhir tidak boleh sebelum tanggal mulai.';
    }
    return null;
  }

  // Format date for display
  String _formatDate(DateTime date) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${two(date.day)}/${two(date.month)}/${date.year}';
  }

  // Get period display text
  String _getPeriodDisplayText() {
    final period = _calculatePeriod(_selectedPeriod);
    if (_selectedPeriod == ExportPeriod.custom) {
      return 'Dari ${_formatDate(period.start)} sampai ${_formatDate(period.end)}';
    }
    return _periodLabels[_selectedPeriod]!;
  }

  // Pick start date
  Future<void> _pickStartDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _customStartDate ?? _now(),
      firstDate: DateTime(2020),
      lastDate: _now(),
      helpText: 'Pilih Tanggal Mulai',
    );
    if (picked != null && mounted) {
      setState(() => _customStartDate = picked);
    }
  }

  // Pick end date
  Future<void> _pickEndDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _customEndDate ?? _now(),
      firstDate: DateTime(2020),
      lastDate: _now(),
      helpText: 'Pilih Tanggal Akhir',
    );
    if (picked != null && mounted) {
      setState(() => _customEndDate = picked);
    }
  }

  // Export transaction data
  Future<void> _exportTransactions() async {
    if (_busy || _restoring || _critical || _exporting) return;

    final validationError = _validateCustomRange();
    if (validationError != null) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(validationError)));
      return;
    }

    // Acquire data transfer lock
    if (!DataTransferLock.acquire()) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Backup/pemulihan/export sedang berjalan.'),
        ),
      );
      return;
    }

    final navigator = Navigator.of(context, rootNavigator: true);
    setState(() => _exporting = true);
    TransactionExportResult? result;

    try {
      final period = _calculatePeriod(_selectedPeriod);
      _progress('Menyiapkan export transaksi...');

      result = await _exportService.export(
        startDate: period.start,
        endDate: period.end,
      );

      if (!mounted) {
        return;
      }

      navigator.pop();
      _progress('Menyimpan file export...');

      // Export file using Android Save-As
      final success = await (widget.saveExport ?? _exportFile)(result);

      if (!mounted) {
        return;
      }

      navigator.pop();

      if (success) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'Export transaksi berhasil disimpan. '
              '${result.transactionCount} transaksi, ${result.itemCount} item.',
            ),
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Penyimpanan export dibatalkan.')),
        );
      }
    } catch (e) {
      if (mounted) {
        navigator.pop();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Export gagal: $e')));
      }
    } finally {
      try {
        await result?.dispose();
      } finally {
        DataTransferLock.release();
        if (mounted) setState(() => _exporting = false);
      }
    }
  }

  // Export file using platform-specific save dialog
  Future<bool> _exportFile(TransactionExportResult result) async {
    if (Platform.isAndroid) {
      return await const MethodChannel('trismart/backup').invokeMethod<bool>(
            'saveExport',
            {'path': result.file.path, 'filename': result.filename},
          ) ??
          false;
    }
    final location = await getSaveLocation(
      suggestedName: result.filename,
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Export TRISMART', extensions: ['zip']),
      ],
    );
    if (location == null) return false;
    await XFile(result.file.path).saveTo(location.path);
    return true;
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
            // Export Transaksi section
            const SizedBox(height: 24),
            const Divider(),
            const SizedBox(height: 16),
            const Text(
              'Export Transaksi',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.bold,
                color: Color(0xFF087F3E),
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Ekspor riwayat transaksi ke file ZIP berisi CSV yang dapat dibuka di Excel.',
              style: TextStyle(fontSize: 13, color: Colors.grey),
            ),
            const SizedBox(height: 16),
            // Period selector
            DropdownButtonFormField<ExportPeriod>(
              initialValue: _selectedPeriod,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Periode',
                border: OutlineInputBorder(),
              ),
              items: _periodLabels.entries
                  .map(
                    (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                  )
                  .toList(),
              onChanged:
                  _busy || _loading || _restoring || _critical || _exporting
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _selectedPeriod = value);
                      }
                    },
            ),
            const SizedBox(height: 12),
            // Selected period info
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: const Color(0xFFF2F7F3),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: Row(
                children: [
                  const Icon(
                    Icons.date_range,
                    size: 20,
                    color: Color(0xFF087F3E),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _getPeriodDisplayText(),
                      style: const TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Custom date pickers
            if (_selectedPeriod == ExportPeriod.custom) ...[
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          _busy ||
                              _loading ||
                              _restoring ||
                              _critical ||
                              _exporting
                          ? null
                          : _pickStartDate,
                      icon: const Icon(Icons.calendar_today, size: 18),
                      label: Text(
                        _customStartDate == null
                            ? 'Dari'
                            : _formatDate(_customStartDate!),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed:
                          _busy ||
                              _loading ||
                              _restoring ||
                              _critical ||
                              _exporting
                          ? null
                          : _pickEndDate,
                      icon: const Icon(Icons.calendar_today, size: 18),
                      label: Text(
                        _customEndDate == null
                            ? 'Sampai'
                            : _formatDate(_customEndDate!),
                      ),
                    ),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 16),
            if (_exporting) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 12),
            ],
            FilledButton(
              onPressed:
                  _busy || _loading || _restoring || _critical || _exporting
                  ? null
                  : _exportTransactions,
              style: FilledButton.styleFrom(
                backgroundColor: const Color(0xFF087F3E),
              ),
              child: Text(
                _exporting ? 'MENGEKSPOR...' : 'EXPORT',
                textAlign: TextAlign.center,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
