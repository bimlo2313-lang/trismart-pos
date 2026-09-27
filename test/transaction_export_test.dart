import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasir_app/database/database_helper.dart';
import 'package:kasir_app/services/backup_service.dart';
import 'package:kasir_app/services/settings_service.dart';
import 'package:kasir_app/services/transaction_export_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseHelper.instance;
  late Directory root;
  late Directory temporary;
  late Database db;
  late TransactionExportService exporter;
  final day = DateTime(2026, 9, 25);
  final backupMeta = {
    'created_at': '2026-09-25T03:45:30.000Z',
    'outlet_code': 'KWD',
    'terminal_code': 'TERM-01',
    'transaction_count': 7,
  };

  TransactionExportService service() => TransactionExportService(
    database: () async => db,
    temporaryDirectory: () async => temporary,
  );

  Future<int> seed({
    required DateTime at,
    required String no,
    int total = 50000,
    int paid = 50000,
    int change = 0,
    String method = 'CASH',
    String status = 'COMPLETED',
    String? outlet = 'KWD',
    String? terminal = 'TERM-01',
    List<Map<String, Object?>> items = const [
      {
        'kode': 'A',
        'barcode': '899',
        'nama': 'Apel',
        'unit': 'PCS',
        'price': 50000,
        'qty': 1,
        'subtotal': 50000,
      },
    ],
  }) async {
    final values = <String, Object?>{
      'transaction_no': no,
      'transaction_date': at.toUtc().toIso8601String(),
      'total': total,
      'payment_method': method,
      'amount_paid': paid,
      'change_amount': change,
      'status': status,
    };
    if (outlet != null) values['outlet_code'] = outlet;
    if (terminal != null) values['terminal_code'] = terminal;
    final id = await db.insert('transactions', values);
    if (outlet == null) {
      await db.rawUpdate('UPDATE transactions SET outlet_code = NULL WHERE id = ?', [id]);
    }
    if (terminal == null) {
      await db.rawUpdate('UPDATE transactions SET terminal_code = NULL WHERE id = ?', [id]);
    }
    for (final item in items) {
      await db.insert('transaction_items', {
        'transaction_id': id,
        'product_id': 1,
        ...item,
      });
    }
    return id;
  }

  Future<Map<String, List<List<String>>>> unzip(TransactionExportResult result) async {
    final archive = ZipDecoder().decodeBytes(await result.file.readAsBytes());
    expect(archive.files.map((f) => f.name).toList()..sort(), [
      'transaction_items.csv',
      'transactions.csv',
    ]);
    Map<String, List<List<String>>> parsed(String name) {
      final file = archive.findFile(name)!;
      final bytes = file.content as List<int>;
      // Verify UTF-8 BOM: 0xEF, 0xBB, 0xBF
      expect(bytes.length >= 3, isTrue, reason: 'File $name should have at least 3 bytes for BOM');
      expect([bytes[0], bytes[1], bytes[2]], equals([0xEF, 0xBB, 0xBF]), reason: 'File $name should start with UTF-8 BOM');
      // Decode the CSV body after the BOM (skip first 3 bytes)
      final text = utf8.decode(bytes.sublist(3));
      return {name: _csvRows(text)};
    }

    return {...parsed('transactions.csv'), ...parsed('transaction_items.csv')};
  }

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    root = await Directory.systemTemp.createTemp('export-test-');
    temporary = await Directory('${root.path}/cache').create();
    await databaseFactory.setDatabasesPath(root.path);
    db = await helper.database;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({
      'last_successful_backup': jsonEncode(backupMeta),
    });
    await SettingsService().save(outletCode: 'DKO', terminalCode: 'TERM-02');
    await db.delete('transaction_items');
    await db.delete('transactions');
    await db.delete('products');
    await db.insert('products', {
      'id': 1,
      'kode': 'MASTER',
      'barcode': 'FALLBACK',
      'nama': 'Master Baru',
      'unit': 'BOX',
      'stok': 10,
      'harga_jual': 1,
    });
    exporter = service();
  });
  tearDown(() async {
    // Clean up any leftover export directories from failed tests
    await for (final entity in temporary.list()) {
      if (entity.path.contains('trismart-export-')) {
        final dir = Directory(entity.path);
        if (await dir.exists()) await dir.delete(recursive: true);
      }
    }
    // Ensure temporary folder is empty
    if (await temporary.exists()) {
      await temporary.delete(recursive: true);
      await temporary.create();
    }
  });
  tearDownAll(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  test('Rentang satu hari inklusif, status apa pun, batas tengah malam', () async {
    await seed(at: day.subtract(const Duration(microseconds: 1)), no: 'BEFORE');
    await seed(at: day, no: 'START');
    await seed(at: DateTime(2026, 9, 25, 23, 59, 59, 999, 999), no: 'END');
    await seed(at: DateTime(2026, 9, 26), no: 'NEXT');
    await seed(at: DateTime(2026, 9, 25, 12), no: 'CANCEL', status: 'CANCELLED');
    final result = await exporter.export(startDate: day, endDate: day);
    expect(result.filename, 'TRISMART_Export_20260925_20260925.zip');
    expect(result.transactionCount, 3);
    expect(result.itemCount, 3);
    final csv = await unzip(result);
    expect(csv['transactions.csv']!.skip(1).map((r) => r[0]), ['START', 'CANCEL', 'END']);
    await result.dispose();
  });

  test('Batas rentang beberapa hari inklusif', () async {
    await seed(at: DateTime(2026, 9, 24, 23, 59, 59), no: 'D24');
    await seed(at: DateTime(2026, 9, 25), no: 'D25');
    await seed(at: DateTime(2026, 9, 26, 23, 59, 59, 999), no: 'D26');
    await seed(at: DateTime(2026, 9, 27), no: 'D27');
    final result = await exporter.export(
      startDate: DateTime(2026, 9, 25, 18),
      endDate: DateTime(2026, 9, 26, 1),
    );
    expect(result.filename, 'TRISMART_Export_20260925_20260926.zip');
    expect(result.startDate, DateTime(2026, 9, 25));
    expect(result.endDate, DateTime(2026, 9, 26));
    final csv = await unzip(result);
    expect(csv['transactions.csv']!.skip(1).map((r) => r[0]), ['D25', 'D26']);
    await result.dispose();
  });

  test('Rentang terbalik ditolak', () async {
    await expectLater(
      exporter.export(startDate: DateTime(2026, 9, 26), endDate: DateTime(2026, 9, 25)),
      throwsA(isA<TransactionExportException>().having(
        (e) => e.message,
        'message',
        'Rentang tanggal tidak valid.',
      )),
    );
    expect(await temporary.list().toList(), isEmpty);
  });

  test('Header dan nilai transactions.csv, uang integer polos', () async {
    await seed(
      at: DateTime(2026, 9, 25, 14, 30, 5),
      no: 'KWD-01-20260925-000001',
      total: 50000,
      paid: 100000,
      change: 50000,
    );
    final result = await exporter.export(startDate: day, endDate: day);
    final raw = utf8.decode(
      ZipDecoder().decodeBytes(await result.file.readAsBytes()).findFile('transactions.csv')!.content,
    );
    expect(raw.contains('Rp'), isFalse);
    expect(raw.contains('50.000'), isFalse);
    expect(raw, contains(',50000,'));
    expect(raw, contains(',100000,'));
    final rows = (await unzip(result))['transactions.csv']!;
    expect(rows.first, [
      'No Transaksi',
      'Tanggal',
      'Jam',
      'Outlet',
      'Terminal',
      'Total',
      'Metode Pembayaran',
      'Dibayar',
      'Kembalian',
      'Status',
    ]);
    expect(rows[1], [
      'KWD-01-20260925-000001',
      '25/09/2026',
      '14:30:05',
      'KWD',
      'TERM-01',
      '50000',
      'CASH',
      '100000',
      '50000',
      'COMPLETED',
    ]);
    await result.dispose();
  });

  test('Header item, snapshot, PLU/barcode nol di depan, barcode kosong', () async {
    await seed(
      at: DateTime(2026, 9, 25, 9),
      no: 'NO-1',
      items: [
        {
          'kode': '000123',
          'barcode': '000999',
          'nama': 'Snapshot Lama',
          'unit': 'PCS',
          'price': 2500,
          'qty': 2,
          'subtotal': 5000,
        },
        {
          'kode': '000456',
          'barcode': '',
          'nama': 'Tanpa Barcode',
          'unit': 'KG',
          'price': 1000,
          'qty': 1,
          'subtotal': 1000,
        },
      ],
    );
    await db.update('products', {
      'kode': 'ZZZ',
      'barcode': 'FALLBACK',
      'nama': 'Jangan Dipakai',
    }, where: 'id = 1');
    final result = await exporter.export(startDate: day, endDate: day);
    final rows = (await unzip(result))['transaction_items.csv']!;
    expect(rows.first, [
      'No Transaksi',
      'Tanggal',
      'Outlet',
      'Terminal',
      'PLU',
      'Barcode',
      'Nama Barang',
      'Unit',
      'Harga',
      'Qty',
      'Subtotal',
    ]);
    expect(rows[1], [
      'NO-1',
      '25/09/2026',
      'KWD',
      'TERM-01',
      '000123',
      '000999',
      'Snapshot Lama',
      'PCS',
      '2500',
      '2',
      '5000',
    ]);
    expect(rows[2][4], '000456');
    expect(rows[2][5], '');
    expect(rows[2][6], 'Tanpa Barcode');
    expect(rows.any((r) => r.contains('ZZZ') || r.contains('FALLBACK') || r.contains('Jangan Dipakai')), isFalse);
    await result.dispose();
  });

  test('NULL outlet/terminal menjadi kosong', () async {
    await seed(at: day, no: 'LEGACY', outlet: null, terminal: null);
    final result = await exporter.export(startDate: day, endDate: day);
    final csv = await unzip(result);
    expect(csv['transactions.csv']![1][3], '');
    expect(csv['transactions.csv']![1][4], '');
    expect(csv['transaction_items.csv']![1][2], '');
    expect(csv['transaction_items.csv']![1][3], '');
    await result.dispose();
  });

  test('Nama dengan koma dan tanda kutip di-escape', () async {
    await seed(
      at: day,
      no: 'ESC',
      items: [
        {
          'kode': 'Q',
          'barcode': 'B',
          'nama': 'Apel, "Merah"',
          'unit': 'PCS',
          'price': 1,
          'qty': 1,
          'subtotal': 1,
        },
      ],
    );
    final result = await exporter.export(startDate: day, endDate: day);
    final raw = utf8.decode(
      ZipDecoder()
          .decodeBytes(await result.file.readAsBytes())
          .findFile('transaction_items.csv')!
          .content,
    );
    expect(raw, contains('"Apel, ""Merah"""'));
    expect((await unzip(result))['transaction_items.csv']![1][6], 'Apel, "Merah"');
    await result.dispose();
  });

  test('Urutan transaksi dan item stabil', () async {
    final later = DateTime(2026, 9, 25, 10);
    final earlier = DateTime(2026, 9, 25, 8);
    await seed(
      at: later,
      no: 'SECOND',
      items: [
        {'kode': 'S1', 'nama': 'S1', 'price': 1, 'qty': 1, 'subtotal': 1},
        {'kode': 'S2', 'nama': 'S2', 'price': 1, 'qty': 1, 'subtotal': 1},
      ],
    );
    await seed(
      at: earlier,
      no: 'FIRST',
      items: [
        {'kode': 'F2', 'nama': 'F2', 'price': 1, 'qty': 1, 'subtotal': 1},
        {'kode': 'F1', 'nama': 'F1', 'price': 1, 'qty': 1, 'subtotal': 1},
      ],
    );
    await db.rawUpdate(
      "UPDATE transaction_items SET id = CASE kode WHEN 'F2' THEN 20 WHEN 'F1' THEN 10 END WHERE kode IN ('F1','F2')",
    );
    final result = await exporter.export(startDate: day, endDate: day);
    final csv = await unzip(result);
    expect(csv['transactions.csv']!.skip(1).map((r) => r[0]), ['FIRST', 'SECOND']);
    expect(csv['transaction_items.csv']!.skip(1).map((r) => r[4]), ['F1', 'F2', 'S1', 'S2']);
    await result.dispose();
  });

  test('Rentang kosong tetap ZIP valid dengan header saja', () async {
    await seed(at: DateTime(2026, 9, 24), no: 'OTHER');
    final result = await exporter.export(startDate: day, endDate: day);
    expect(result.transactionCount, 0);
    expect(result.itemCount, 0);
    final csv = await unzip(result);
    expect(csv['transactions.csv'], hasLength(1));
    expect(csv['transaction_items.csv'], hasLength(1));
    expect(csv['transactions.csv']!.first.first, 'No Transaksi');
    expect(csv['transaction_items.csv']!.first[4], 'PLU');
    await result.dispose();
  });

  test('Export tidak mengubah stok, transaksi, pengaturan, atau backup terakhir', () async {
    await seed(at: day, no: 'KEEP');
    final beforeTx = await db.query('transactions');
    final beforeItems = await db.query('transaction_items');
    final beforeProducts = await db.query('products');
    final result = await exporter.export(startDate: day, endDate: day);
    expect(await db.query('transactions'), beforeTx);
    expect(await db.query('transaction_items'), beforeItems);
    expect(await db.query('products'), beforeProducts);
    expect((await db.query('products')).single['stok'], 10);
    expect((await SettingsService().load())!.deviceIdentity, 'DKO-TERM-02');
    expect(await BackupService().lastBackup(), backupMeta);
    expect(await db.getVersion(), 5);
    await result.dispose();
  });

  test('Berkas sementara dapat dibersihkan', () async {
    await seed(at: day, no: 'TEMP');
    final result = await exporter.export(startDate: day, endDate: day);
    expect(await result.file.exists(), isTrue);
    expect(await temporary.list().toList(), isNotEmpty);
    await result.dispose();
    expect(await result.file.exists(), isFalse);
    expect(await temporary.list().toList(), isEmpty);
  });
}

List<List<String>> _csvRows(String text) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final ch = text[i];
    if (quoted) {
      if (ch == '"' && i + 1 < text.length && text[i + 1] == '"') {
        field.write('"');
        i++;
      } else if (ch == '"') {
        quoted = false;
      } else {
        field.write(ch);
      }
      continue;
    }
    if (ch == '"') {
      quoted = true;
    } else if (ch == ',') {
      row.add(field.toString());
      field.clear();
    } else if (ch == '\n') {
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = [];
    } else if (ch != '\r') {
      field.write(ch);
    }
  }
  return rows;
}
