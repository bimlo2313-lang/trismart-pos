import 'dart:convert';

import 'package:csv/csv.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';

import '../database/database_helper.dart';

class ImportResult {
  final int totalRows;
  final int imported;
  final int skipped;
  final String? error;

  const ImportResult({
    required this.totalRows,
    required this.imported,
    required this.skipped,
    this.error,
  });
}

class ImportService {
  final DatabaseHelper _databaseHelper = DatabaseHelper.instance;

  Future<ImportResult> importCsv() async {
    try {
      // =========================================================
      // PILIH FILE CSV
      // =========================================================

      const XTypeGroup typeGroup = XTypeGroup(
        label: 'CSV',
        extensions: <String>['csv'],
      );

      final XFile? file = await openFile(
        acceptedTypeGroups: <XTypeGroup>[typeGroup],
      );

      if (file == null) {
        return const ImportResult(
          totalRows: 0,
          imported: 0,
          skipped: 0,
          error: 'IMPORT_DIBATALKAN',
        );
      }

      // =========================================================
      // BACA FILE
      // =========================================================

      final Uint8List bytes = await file.readAsBytes();

      // Parsing CSV dilakukan di background isolate.
      // Jadi UI tidak terlalu terbebani.
      final CsvParseResult parsed = await compute(
        parseCsvInBackground,
        bytes,
      );

      if (parsed.error != null) {
        return ImportResult(
          totalRows: parsed.totalRows,
          imported: 0,
          skipped: parsed.skipped,
          error: parsed.error,
        );
      }

      if (parsed.products.isEmpty) {
        return ImportResult(
          totalRows: parsed.totalRows,
          imported: 0,
          skipped: parsed.skipped,
          error: 'Tidak ada data barang yang dapat diimport.',
        );
      }

      // =========================================================
      // MASUKKAN KE SQLITE PER 500 BARANG
      // =========================================================

      const int batchSize = 500;

      int imported = 0;

      for (int i = 0; i < parsed.products.length; i += batchSize) {
        final int end =
            (i + batchSize < parsed.products.length)
                ? i + batchSize
                : parsed.products.length;

        final batch = parsed.products.sublist(i, end);

        await _databaseHelper.importProductsBatch(batch);

        imported += batch.length;

        // Beri kesempatan UI bernafas sebentar.
        await Future<void>.delayed(
          const Duration(milliseconds: 1),
        );
      }

      return ImportResult(
        totalRows: parsed.totalRows,
        imported: imported,
        skipped: parsed.skipped,
      );
    } catch (e) {
      return ImportResult(
        totalRows: 0,
        imported: 0,
        skipped: 0,
        error: e.toString(),
      );
    }
  }
}

// ===============================================================
// HASIL PARSING CSV
// ===============================================================

class CsvParseResult {
  final List<Map<String, dynamic>> products;
  final int totalRows;
  final int skipped;
  final String? error;

  const CsvParseResult({
    required this.products,
    required this.totalRows,
    required this.skipped,
    this.error,
  });
}

// ===============================================================
// FUNGSI INI BERJALAN DI BACKGROUND ISOLATE
// ===============================================================

CsvParseResult parseCsvInBackground(Uint8List bytes) {
  try {
    String csvText = utf8.decode(
      bytes,
      allowMalformed: true,
    );

    // Buang UTF-8 BOM bila ada.
    if (csvText.startsWith('\uFEFF')) {
      csvText = csvText.substring(1);
    }

    final List<List<dynamic>> rows = csv.decode(csvText);

    if (rows.isEmpty) {
      return const CsvParseResult(
        products: [],
        totalRows: 0,
        skipped: 0,
        error: 'File CSV kosong.',
      );
    }

    // ===========================================================
    // CARI HEADER
    // ===========================================================

    final headerRow = rows.first;

    int? kodeIndex;
    int? namaIndex;
    int? qtyIndex;
    int? unitIndex;
    int? hargaIndex;
    int? barcodeIndex;

    for (int i = 0; i < headerRow.length; i++) {
      final header = headerRow[i]
          .toString()
          .trim()
          .toLowerCase();

      switch (header) {
        case 'kode':
          kodeIndex = i;
          break;

        case 'nama':
          namaIndex = i;
          break;

        case 'qty':
          qtyIndex = i;
          break;

        case 'unit':
          unitIndex = i;
          break;

        case 'hrg sat 1':
          hargaIndex = i;
          break;

        case 'barcode 1':
          barcodeIndex = i;
          break;
      }
    }

    // ===========================================================
    // VALIDASI HEADER
    // ===========================================================

    if (kodeIndex == null ||
        namaIndex == null ||
        qtyIndex == null ||
        unitIndex == null ||
        hargaIndex == null ||
        barcodeIndex == null) {
      return const CsvParseResult(
        products: [],
        totalRows: 0,
        skipped: 0,
        error:
            'Kolom wajib tidak lengkap.\n'
            'Wajib ada:\n'
            'Kode\n'
            'Nama\n'
            'Qty\n'
            'Unit\n'
            'Hrg Sat 1\n'
            'Barcode 1',
      );
    }

    // ===========================================================
    // PARSING BARANG
    // ===========================================================

    final List<Map<String, dynamic>> products = [];

    int skipped = 0;

    for (int i = 1; i < rows.length; i++) {
      final row = rows[i];

      // Lewati baris kosong.
      if (row.isEmpty) {
        skipped++;
        continue;
      }

      final kode = _cellValue(row, kodeIndex);
      final nama = _cellValue(row, namaIndex);
      final qty = _cellValue(row, qtyIndex);
      final unit = _cellValue(row, unitIndex);
      final harga = _cellValue(row, hargaIndex);
      final barcode = _cellValue(row, barcodeIndex);

      // Kode / PLU dan Nama wajib tersedia.
      if (kode.isEmpty || nama.isEmpty) {
        skipped++;
        continue;
      }

      final product = <String, dynamic>{
        'kode': _normalizeCode(kode),
        'nama': nama,
        'stok': _parseNumber(qty),
        'unit': unit,
        'harga_jual': _parseNumber(harga),
        'barcode': _normalizeBarcode(barcode),
        'lokasi': 'DOKO',
        'aktif': 1,
      };

      products.add(product);
    }

    return CsvParseResult(
      products: products,
      totalRows: rows.length - 1,
      skipped: skipped,
    );
  } catch (e) {
    return CsvParseResult(
      products: const [],
      totalRows: 0,
      skipped: 0,
      error: 'Gagal membaca CSV: $e',
    );
  }
}

// ===============================================================
// AMBIL CELL DENGAN AMAN
// ===============================================================

String _cellValue(
  List<dynamic> row,
  int index,
) {
  if (index >= row.length) {
    return '';
  }

  final value = row[index];

  if (value == null) {
    return '';
  }

  return value.toString().trim();
}

// ===============================================================
// KONVERSI QTY / HARGA
// ===============================================================

double _parseNumber(String value) {
  if (value.isEmpty) {
    return 0;
  }

  String cleaned = value.trim();

  // Contoh:
  // 12,000.00
  // menjadi:
  // 12000.00

  cleaned = cleaned.replaceAll(',', '');

  return double.tryParse(cleaned) ?? 0;
}

// ===============================================================
// NORMALISASI KODE / PLU
// ===============================================================

String _normalizeCode(String value) {
  String result = value.trim();

  // Kalau CSV menghasilkan contoh 12345.0,
  // ubah menjadi 12345.
  if (result.endsWith('.0')) {
    final withoutDecimal =
        result.substring(0, result.length - 2);

    if (int.tryParse(withoutDecimal) != null) {
      result = withoutDecimal;
    }
  }

  return result;
}

// ===============================================================
// NORMALISASI BARCODE
// ===============================================================

String? _normalizeBarcode(String value) {
  String result = value.trim();

  if (result.isEmpty) {
    return null;
  }

  if (result.endsWith('.0')) {
    final withoutDecimal =
        result.substring(0, result.length - 2);

    if (int.tryParse(withoutDecimal) != null) {
      result = withoutDecimal;
    }
  }

  // Aturan yang sudah kita sepakati:
  // abaikan SATU angka 0 paling depan.
  //
  // 0123456 -> 123456
  // 123456  -> 123456

  if (result.startsWith('0') &&
      result.length > 1) {
    result = result.substring(1);
  }

  return result;
}