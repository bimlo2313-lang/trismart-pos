import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

import '../database/database_helper.dart';

class TransactionExportException implements Exception {
  const TransactionExportException(this.message);
  final String message;
  @override
  String toString() => message;
}

class TransactionExportResult {
  TransactionExportResult({
    required this.file,
    required this.filename,
    required this.startDate,
    required this.endDate,
    required this.transactionCount,
    required this.itemCount,
    required this.directory,
  });
  final File file;
  final String filename;
  final DateTime startDate;
  final DateTime endDate;
  final int transactionCount;
  final int itemCount;
  final Directory directory;

  Future<void> dispose() async {
    if (await directory.exists()) await directory.delete(recursive: true);
  }
}

class TransactionExportService {
  TransactionExportService({
    Future<Database> Function()? database,
    Future<Directory> Function()? temporaryDirectory,
  }) : _database = database ?? (() => DatabaseHelper.instance.database),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory;
  final Future<Database> Function() _database;
  final Future<Directory> Function() _temporaryDirectory;

  static String filename(DateTime startDate, DateTime endDate) {
    String ymd(DateTime date) {
      String two(int value) => value.toString().padLeft(2, '0');
      return '${date.year.toString().padLeft(4, '0')}${two(date.month)}${two(date.day)}';
    }

    return 'TRISMART_Export_${ymd(startDate)}_${ymd(endDate)}.zip';
  }

  Future<TransactionExportResult> export({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    final start = DateTime(startDate.year, startDate.month, startDate.day);
    final end = DateTime(endDate.year, endDate.month, endDate.day);
    if (end.isBefore(start)) {
      throw const TransactionExportException('Rentang tanggal tidak valid.');
    }
    Directory? area;
    try {
      area = await (await _temporaryDirectory()).createTemp('trismart-export-');
      final db = await _database();
      final from = _boundary(start, 0);
      final until = _boundary(end, 1);
      final transactions = await db.rawQuery(
        '''
        SELECT * FROM transactions
        WHERE transaction_date >= ? AND transaction_date < ?
        ORDER BY transaction_date ASC, id ASC
        ''',
        [from, until],
      );
      final items = await db.rawQuery(
        '''
        SELECT i.kode, i.barcode, i.nama, i.unit, i.price, i.qty, i.subtotal,
          t.transaction_no, t.transaction_date, t.outlet_code, t.terminal_code
        FROM transaction_items i
        INNER JOIN transactions t ON t.id = i.transaction_id
        WHERE t.transaction_date >= ? AND t.transaction_date < ?
        ORDER BY t.transaction_date ASC, t.id ASC, i.id ASC
        ''',
        [from, until],
      );
      final name = filename(start, end);
      final file = File(p.join(area.path, name));
      await file.writeAsBytes(
        ZipEncoder().encodeBytes(
          Archive()
            ..add(
              ArchiveFile.bytes(
                'transactions.csv',
                _csvBytes(_transactionsCsv(transactions)),
              ),
            )
            ..add(
              ArchiveFile.bytes(
                'transaction_items.csv',
                _csvBytes(_itemsCsv(items)),
              ),
            ),
        ),
      );
      return TransactionExportResult(
        file: file,
        filename: name,
        startDate: start,
        endDate: end,
        transactionCount: transactions.length,
        itemCount: items.length,
        directory: area,
      );
    } catch (error) {
      if (area != null && await area.exists()) {
        await area.delete(recursive: true);
      }
      rethrow;
    }
  }

  // Hari lokal; transaction_date tersimpan sebagai ISO UTC.
  static String _boundary(DateTime date, int extraDays) {
    final utc = DateTime(date.year, date.month, date.day + extraDays).toUtc();
    return '${utc.toIso8601String().substring(0, 19)}.000000Z';
  }

  static List<int> _csvBytes(String body) =>
      [...utf8.encode('\uFEFF'), ...utf8.encode(body)];

  static String _transactionsCsv(List<Map<String, Object?>> rows) {
    final lines = <String>[
      _line(const [
        (value: 'No Transaksi', quote: true),
        (value: 'Tanggal', quote: true),
        (value: 'Jam', quote: true),
        (value: 'Outlet', quote: true),
        (value: 'Terminal', quote: true),
        (value: 'Total', quote: false),
        (value: 'Metode Pembayaran', quote: true),
        (value: 'Dibayar', quote: false),
        (value: 'Kembalian', quote: false),
        (value: 'Status', quote: true),
      ]),
    ];
    for (final row in rows) {
      final local = _localDateTime(row['transaction_date'] as String?);
      lines.add(
        _line([
          (value: row['transaction_no'], quote: true),
          (value: local.date, quote: true),
          (value: local.time, quote: true),
          (value: row['outlet_code'], quote: true),
          (value: row['terminal_code'], quote: true),
          (value: row['total'], quote: false),
          (value: row['payment_method'], quote: true),
          (value: row['amount_paid'], quote: false),
          (value: row['change_amount'], quote: false),
          (value: row['status'], quote: true),
        ]),
      );
    }
    return '${lines.join('\r\n')}\r\n';
  }

  static String _itemsCsv(List<Map<String, Object?>> rows) {
    final lines = <String>[
      _line(const [
        (value: 'No Transaksi', quote: true),
        (value: 'Tanggal', quote: true),
        (value: 'Outlet', quote: true),
        (value: 'Terminal', quote: true),
        (value: 'PLU', quote: true),
        (value: 'Barcode', quote: true),
        (value: 'Nama Barang', quote: true),
        (value: 'Unit', quote: true),
        (value: 'Harga', quote: false),
        (value: 'Qty', quote: false),
        (value: 'Subtotal', quote: false),
      ]),
    ];
    for (final row in rows) {
      lines.add(
        _line([
          (value: row['transaction_no'], quote: true),
          (
            value: _localDateTime(row['transaction_date'] as String?).date,
            quote: true,
          ),
          (value: row['outlet_code'], quote: true),
          (value: row['terminal_code'], quote: true),
          (value: row['kode'], quote: true),
          (value: row['barcode'], quote: true),
          (value: row['nama'], quote: true),
          (value: row['unit'], quote: true),
          (value: row['price'], quote: false),
          (value: row['qty'], quote: false),
          (value: row['subtotal'], quote: false),
        ]),
      );
    }
    return '${lines.join('\r\n')}\r\n';
  }

  static ({String date, String time}) _localDateTime(String? value) {
    final parsed = DateTime.tryParse(value ?? '');
    if (parsed == null) return (date: value ?? '', time: '');
    final local = parsed.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return (
      date: '${two(local.day)}/${two(local.month)}/${local.year}',
      time: '${two(local.hour)}:${two(local.minute)}:${two(local.second)}',
    );
  }

  static String _line(List<({Object? value, bool quote})> cells) {
    return cells
        .map((cell) {
          if (!cell.quote) return _integer(cell.value);
          final text = cell.value?.toString() ?? '';
          return '"${text.replaceAll('"', '""')}"';
        })
        .join(',');
  }

  static String _integer(Object? value) {
    if (value is int) return '$value';
    if (value is num) return '${value.round()}';
    return '${value ?? 0}';
  }
}
