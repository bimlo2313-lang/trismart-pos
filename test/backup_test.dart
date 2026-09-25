import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasir_app/database/database_helper.dart';
import 'package:kasir_app/models/outlet.dart';
import 'package:kasir_app/pages/backup_section.dart';
import 'package:kasir_app/services/backup_service.dart';
import 'package:kasir_app/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart' show Sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late Directory temporary;
  late Database db;
  final time = DateTime(2026, 9, 25, 10, 45, 30);
  late File exported;

  BackupService service({
    BackupExporter? export,
    Future<Database> Function()? database,
  }) => BackupService(
    database: database ?? () async => db,
    temporaryDirectory: () async => temporary,
    now: () => time,
    exportFile:
        export ??
        (file, name) async {
          await file.copy(exported.path);
          return true;
        },
  );

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    root = await Directory.systemTemp.createTemp('backup-test-');
    temporary = await Directory('${root.path}/temporary').create();
    exported = File('${root.path}/export.trismart');
    await databaseFactory.setDatabasesPath(root.path);
    db = await DatabaseHelper.instance.database;
    await db.rawQuery('PRAGMA journal_mode=WAL');
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await db.delete('transaction_items');
    await db.delete('transactions');
    await db.delete('products');
    await db.insert('products', {
      'id': 1,
      'kode': 'A',
      'nama': 'Apel',
      'stok': 10,
    });
    await db.insert('transactions', {
      'id': 1,
      'transaction_no': 'KWD-01-20260925-000001',
      'transaction_date': time.toUtc().toIso8601String(),
      'total': 2000,
      'payment_method': 'CASH',
      'amount_paid': 2000,
      'change_amount': 0,
      'outlet_code': 'KWD',
      'terminal_code': 'TERM-01',
    });
    await db.insert('transaction_items', {
      'transaction_id': 1,
      'product_id': 1,
      'kode': 'A',
      'nama': 'Apel',
      'price': 1000,
      'qty': 2,
      'subtotal': 2000,
    });
  });
  tearDownAll(() async {
    await db.close();
    await root.delete(recursive: true);
  });

  test('Nama file lokal memakai identitas atau UNSET', () {
    expect(
      BackupService.filename(
        time,
        const CashierIdentity(outletCode: 'KWD', terminalCode: 'TERM-01'),
      ),
      'TRISMART_Backup_KWD_TERM-01_20260925_104530.trismart',
    );
    expect(
      BackupService.filename(time, null),
      'TRISMART_Backup_UNSET_20260925_104530.trismart',
    );
    expect(
      BackupService.filename(
        time,
        const CashierIdentity(outletCode: '../X', terminalCode: 'T/1'),
      ),
      isNot(contains('/')),
    );
  });

  test(
    'Archive SQLite lengkap, metadata, COUNT dan checksum cocok; WAL aman',
    () async {
      await SettingsService().save(outletCode: 'KWD', terminalCode: 'TERM-01');
      final before = await db.query('transactions');
      final result = (await service().createBackup())!;
      final archive = ZipDecoder().decodeBytes(await exported.readAsBytes());
      expect(archive.files.map((f) => f.name).toSet(), {
        'database.sqlite',
        'metadata.json',
      });
      final meta =
          jsonDecode(utf8.decode(archive.findFile('metadata.json')!.content))
              as Map<String, dynamic>;
      final bytes = archive.findFile('database.sqlite')!.content;
      expect(meta, result.metadata);
      expect(meta['format'], 'TRISMART_BACKUP');
      expect(meta['backup_format_version'], 1);
      expect(meta['database_version'], 5);
      expect(meta['created_at'], time.toUtc().toIso8601String());
      expect(meta['outlet_code'], 'KWD');
      expect(meta['terminal_code'], 'TERM-01');
      expect(meta['database_file'], 'database.sqlite');
      expect(meta['database_sha256'], sha256.convert(bytes).toString());
      expect(meta['transaction_count'], 1);
      expect(meta['product_count'], 1);
      final checkedFile = File('${root.path}/check.sqlite');
      await checkedFile.writeAsBytes(bytes);
      final checked = await openDatabase(
        checkedFile.path,
        readOnly: true,
        singleInstance: false,
      );
      try {
        expect(await checked.rawQuery('PRAGMA integrity_check'), [
          {'integrity_check': 'ok'},
        ]);
        expect(await checked.query('transactions'), before);
        expect(
          await checked.query('transaction_items'),
          await db.query('transaction_items'),
        );
        expect(await checked.query('products'), await db.query('products'));
      } finally {
        await checked.close();
        await checkedFile.delete();
      }
      expect(await service().lastBackup(), meta);
      expect(await temporary.list().toList(), isEmpty);
      expect(await db.query('transactions'), before);
      expect(db.isOpen, isTrue);
    },
  );

  test(
    'Snapshot menunggu transaksi aktif dan COUNT berasal dari snapshot',
    () async {
      final started = Completer<void>();
      final release = Completer<void>();
      final write = db.transaction((txn) async {
        await txn.insert('products', {'kode': 'B', 'nama': 'Beras'});
        started.complete();
        await release.future;
      });
      await started.future;
      var exportedFile = false;
      final backup = service(
        export: (file, name) async {
          exportedFile = true;
          // Penulisan setelah snapshot tidak boleh mengubah count metadata.
          await db.insert('products', {'kode': 'C', 'nama': 'Cabai'});
          return true;
        },
      ).createBackup();
      await Future<void>.delayed(const Duration(milliseconds: 30));
      expect(exportedFile, isFalse);
      release.complete();
      await write;
      expect((await backup)!.metadata['product_count'], 2);
      expect(
        Sqflite.firstIntValue(
          await db.rawQuery('SELECT COUNT(*) FROM products'),
        ),
        3,
      );
      expect(await temporary.list().toList(), isEmpty);
    },
  );

  test(
    'Cancel bukan sukses/gagal dan tidak mengubah catatan terakhir',
    () async {
      await service().createBackup();
      final last = await service().lastBackup();
      final cancelled = await service(
        export: (file, name) async {
          expect(name, contains('UNSET'));
          expect(await file.exists(), isTrue);
          return false;
        },
      ).createBackup();
      expect(cancelled, isNull);
      expect(await service().lastBackup(), last);
      expect(await temporary.list().toList(), isEmpty);
    },
  );

  test(
    'Gagal snapshot/export menjaga database dan catatan; temporary dibersihkan',
    () async {
      await service().createBackup();
      final last = await service().lastBackup();
      final before = await db.query('products');
      await expectLater(
        service(
          export: (_, _) async =>
              throw const FileSystemException('Simulated failure'),
        ).createBackup(),
        throwsA(isA<FileSystemException>()),
      );
      // Buka read-only terpisah yang sudah ditutup untuk simulasi snapshot gagal.
      final closed = await openDatabase(
        '${root.path}/closed.sqlite',
        singleInstance: false,
      );
      await closed.close();
      await expectLater(
        service(database: () async => closed).createBackup(),
        throwsA(isA<DatabaseException>()),
      );
      expect(await service().lastBackup(), last);
      expect(await db.query('products'), before);
      expect(await temporary.list().toList(), isEmpty);
      await db.update('products', {'stok': 9}, where: 'id = 1');
      expect((await db.query('products')).single['stok'], 9);
    },
  );

  testWidgets('UI sukses memperbarui info, cancel diam, gagal memberi pesan', (
    tester,
  ) async {
    final fake = _FakeBackupService();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(child: BackupSection(service: fake)),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Belum pernah'), findsOneWidget);
    await tester.tap(find.text('BUAT BACKUP'));
    await tester.pumpAndSettle();
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('Belum pernah'), findsOneWidget);
    fake.result = BackupResult({
      'created_at': time.toUtc().toIso8601String(),
      'outlet_code': 'KWD',
      'terminal_code': 'TERM-01',
      'transaction_count': 7,
    }, historySaved: true);
    await tester.tap(find.text('BUAT BACKUP'));
    await tester.pumpAndSettle();
    expect(find.text('Kawedusan • TERM-01'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
    expect(find.text('Backup berhasil disimpan.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    fake.fail = true;
    await tester.tap(find.text('BUAT BACKUP'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Backup gagal dibuat'), findsOneWidget);
    expect(find.text('7'), findsOneWidget);
  });
}

class _FakeBackupService extends BackupService {
  BackupResult? result;
  bool fail = false;
  @override
  Future<Map<String, dynamic>?> lastBackup() async => null;
  @override
  Future<BackupResult?> createBackup() async {
    if (fail) throw StateError('Simulated failure');
    return result;
  }
}
