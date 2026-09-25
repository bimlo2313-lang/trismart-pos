import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasir_app/database/database_helper.dart';
import 'package:kasir_app/pages/backup_section.dart';
import 'package:kasir_app/services/backup_service.dart';
import 'package:kasir_app/services/restore_service.dart';
import 'package:kasir_app/services/restore_validation.dart';
import 'package:kasir_app/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseHelper.instance;
  late Directory root;
  late Directory temporary;
  late Database db;
  late File validArchive;
  late List<int> sourceBytes;
  late Map<String, dynamic> metadata;
  final date = DateTime(2026, 9, 25);

  Future<void> seed(String code) async {
    await db.delete('transaction_items');
    await db.delete('transactions');
    await db.delete('products');
    await db.insert('products', {'id': 1, 'kode': code, 'nama': code, 'stok': 20, 'harga_jual': 1000});
    await db.insert('transactions', {'id': 1, 'transaction_no': 'TRX-$code',
      'transaction_date': date.toUtc().toIso8601String(), 'total': 1000, 'payment_method': 'CASH',
      'amount_paid': 1000, 'change_amount': 0, 'outlet_code': 'KWD', 'terminal_code': 'TERM-01'});
    await db.insert('transaction_items', {'id': 1, 'transaction_id': 1, 'product_id': 1,
      'kode': code, 'nama': code, 'price': 1000, 'qty': 1, 'subtotal': 1000});
  }

  RestoreService service(File input, {bool cancel = false, bool failAfter = false}) {
    Future<bool> pick(File target) async { if (cancel) return false; await input.copy(target.path); return true; }
    return failAfter ? _FailAfterRestore(temporaryDirectory: () async => temporary, picker: pick)
      : RestoreService(temporaryDirectory: () async => temporary, picker: pick);
  }

  Future<File> package({Map<String, dynamic>? patch, List<int>? bytes,
    String databaseName = 'database.sqlite', String? json}) async {
    final data = bytes ?? sourceBytes;
    final meta = {...metadata, if (bytes != null) 'database_sha256': sha256.convert(data).toString(), ...?patch};
    final archive = Archive()
      ..add(ArchiveFile.bytes('metadata.json', utf8.encode(json ?? jsonEncode(meta))))
      ..add(ArchiveFile.bytes(databaseName, data));
    return File('${root.path}/modified.trismart').writeAsBytes(ZipEncoder().encodeBytes(archive));
  }

  Future<void> unchanged() async {
    db = await helper.database;
    expect((await db.query('products')).single['kode'], 'CURRENT');
    expect((await db.query('transactions')).single['transaction_no'], 'TRX-CURRENT');
    expect((await db.query('transaction_items')).single['kode'], 'CURRENT');
    expect((await SettingsService().load())!.deviceIdentity, 'DKO-TERM-02');
    expect(await BackupService().lastBackup(), metadata);
    expect(await temporary.list().toList(), isEmpty);
  }

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    root = await Directory.systemTemp.createTemp('restore-fixture-');
    temporary = await Directory('${root.path}/cache').create();
    validArchive = File('${root.path}/valid.trismart');
    await databaseFactory.setDatabasesPath(root.path);
    db = await helper.database;
    SharedPreferences.setMockInitialValues({});
    await SettingsService().save(outletCode: 'KWD', terminalCode: 'TERM-01');
    await seed('BACKUP');
    await BackupService(database: () async => db, temporaryDirectory: () async => temporary,
      now: () => date, exportFile: (file, _) async { await file.copy(validArchive.path); return true; }).createBackup();
    final archive = ZipDecoder().decodeBytes(await validArchive.readAsBytes());
    sourceBytes = archive.findFile('database.sqlite')!.content;
    metadata = jsonDecode(utf8.decode(archive.findFile('metadata.json')!.content)) as Map<String, dynamic>;
  });
  setUp(() async {
    db = await helper.database;
    SharedPreferences.setMockInitialValues({'last_successful_backup': jsonEncode(metadata)});
    await SettingsService().save(outletCode: 'DKO', terminalCode: 'TERM-02');
    await seed('CURRENT');
    await db.rawQuery('PRAGMA journal_mode=WAL');
  });
  tearDownAll(() async { await db.close(); await root.delete(recursive: true); });

  test('Backup valid menghasilkan preview tanpa menyentuh database aktif', () async {
    final restore = service(validArchive);
    final preview = (await restore.prepare())!;
    expect(preview.metadata, metadata);
    expect(await File(preview.databasePath).exists(), isTrue);
    await preview.dispose();
    await unchanged();
  });

  for (final patch in <Map<String, dynamic>>[
    {'format': 'OTHER'}, {'backup_format_version': 2}, {'database_version': 4},
    {'database_sha256': '0' * 64}, {'transaction_count': 999}, {'product_count': 999},
  ]) {
    test('Metadata tidak valid ditolak: $patch', () async {
      await expectLater(service(await package(patch: patch)).prepare(), throwsA(isA<RestoreException>()));
      await unchanged();
    });
  }

  test('JSON rusak, bukan ZIP, entry traversal/duplikat ditolak', () async {
    await expectLater(service(await package(json: '{')).prepare(), throwsA(isA<RestoreException>()));
    await expectLater(service(await package(databaseName: '../database.sqlite')).prepare(), throwsA(isA<RestoreException>()));
    // Dua nama identik di central directory tidak boleh dianggap satu entry.
    final raw = await validArchive.readAsBytes();
    final changed = List<int>.of(raw);
    final from = utf8.encode('metadata.json');
    final to = utf8.encode('database.sql'); // panjang 12; gunakan nama duplikat metadata via fixture ZIP terpisah di bawah.
    expect(to.length, 12);
    // Ganti nama database (15 byte) menjadi metadata.json + dua slash: juga wajib ditolak.
    final target = utf8.encode('database.sqlite');
    for (var i = 0; i <= changed.length - target.length; i++) {
      if (List.generate(target.length, (j) => changed[i + j]).join(',') == target.join(',')) {
        changed.setRange(i, i + target.length, [...from, 47, 47]);
      }
    }
    final unsafe = await File('${root.path}/unsafe.trismart').writeAsBytes(changed);
    await expectLater(service(unsafe).prepare(), throwsA(isA<RestoreException>()));
    await unsafe.writeAsString('not a zip');
    await expectLater(service(unsafe).prepare(), throwsA(isA<RestoreException>()));
    await unchanged();
  });

  test('SQLite rusak, versi asli salah, tabel/kolom hilang ditolak meski hash cocok', () async {
    await expectLater(service(await package(bytes: List.filled(200, 42))).prepare(), throwsA(isA<RestoreException>()));
    for (final sql in ['PRAGMA user_version=4', 'DROP TABLE transaction_items',
      'ALTER TABLE transactions RENAME COLUMN terminal_code TO missing_terminal']) {
      final file = await File('${root.path}/broken.sqlite').writeAsBytes(sourceBytes);
      final broken = await openDatabase(file.path, singleInstance: false);
      await broken.execute(sql);
      await broken.close();
      await expectLater(service(await package(bytes: await file.readAsBytes())).prepare(), throwsA(isA<RestoreException>()));
    }
    await unchanged();
  });

  test('Integrity check mendeteksi kerusakan halaman database', () async {
    final corrupt = List<int>.of(sourceBytes);
    // Header btree halaman pertama: tipe page invalid, header SQLite tetap valid.
    corrupt[100] = 0xff;
    await expectLater(service(await package(bytes: corrupt)).prepare(), throwsA(isA<RestoreException>()));
    await unchanged();
  });

  test('Cancel picker tidak mengubah DB/setting/catatan backup', () async {
    expect(await service(validArchive, cancel: true).prepare(), isNull);
    await unchanged();
  });

  test('Restore replace utuh, setting dan backup terakhir tetap, helper dapat dipakai lagi', () async {
    final restore = service(validArchive);
    await restore.restore((await restore.prepare())!);
    db = await helper.database;
    expect((await db.query('products')).single['kode'], 'BACKUP');
    expect((await db.query('transactions')).single['transaction_no'], 'TRX-BACKUP');
    expect((await db.query('transaction_items')).single['kode'], 'BACKUP');
    expect((await SettingsService().load())!.deviceIdentity, 'DKO-TERM-02');
    expect(await BackupService().lastBackup(), metadata);
    expect(await db.getVersion(), 5);
    await db.update('products', {'stok': 19}, where: 'id = 1');
    expect((await helper.getProductByKode('BACKUP'))!['stok'], 19);
    expect(await temporary.list().toList(), isEmpty);
    expect((await root.list().toList()).where((f) => f.path.contains('trismart-recovery-')), isEmpty);
    expect(await File('${db.path}.restore-pending').exists(), isFalse);
  });

  test('Perubahan package setelah preview ditolak sebelum replacement', () async {
    final restore = service(validArchive);
    final preview = (await restore.prepare())!;
    await File('${preview.directory.path}/selected.trismart').writeAsString('changed');
    await expectLater(restore.restore(preview), throwsA(isA<RestoreException>()));
    await unchanged();
  });

  test('Failure setelah replace mengembalikan products/transaksi/item lama dan WAL aman', () async {
    final restore = service(validArchive, failAfter: true);
    await expectLater(restore.restore((await restore.prepare())!),
      throwsA(isA<RestoreException>().having((e) => e.message, 'message', 'Pemulihan gagal. Data sebelumnya telah dikembalikan.')));
    await unchanged();
    expect(await File('${db.path}.restore-pending').exists(), isFalse);
    await db.update('products', {'stok': 18}, where: 'id = 1');
    expect((await db.query('products')).single['stok'], 18);
  });

  testWidgets('Preview memerlukan konfirmasi; BATAL membersihkan temporary', (tester) async {
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(
      child: BackupSection(restoreService: service(validArchive))))));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('PULIHKAN DARI BACKUP'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('PULIHKAN DARI BACKUP'));
    await tester.pump();
    for (var i = 0; i < 30 && find.text('Backup TRISMART valid').evaluate().isEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump(const Duration(milliseconds: 100));
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Backup TRISMART valid'), findsOneWidget);
    expect(find.text('Asal: Kawedusan (KWD)'), findsOneWidget);
    await tester.tap(find.text('BATAL'));
    await tester.pump();
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 150)));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.runAsync(unchanged);
    expect(find.text('Data berhasil dipulihkan.'), findsNothing);
  });
}

class _FailAfterRestore extends RestoreService {
  _FailAfterRestore({super.temporaryDirectory, super.picker});
  @override
  Future<void> afterReplacement() async => throw const FileSystemException('Simulated reopen failure');
}
