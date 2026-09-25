import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasir_app/database/database_helper.dart';
import 'package:kasir_app/models/cash_transaction.dart';
import 'package:kasir_app/pages/transaction_detail_page.dart';
import 'package:kasir_app/pages/transaction_page.dart';
import 'package:kasir_app/services/settings_service.dart';
import 'package:path/path.dart' as path;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseHelper.instance;
  late Directory directory;
  late Database db;
  late List<Map<String, Object?>> oldTransactions;
  late List<Map<String, Object?>> oldItems;
  late List<Map<String, Object?>> oldProducts;
  late List<Map<String, Object?>> migratedProducts;
  const item = TransactionItem(
    productId: 1,
    kode: 'A',
    nama: 'Apel',
    price: 1000,
    qty: 2,
  );

  Future<CashReceipt> complete({List<TransactionItem> items = const [item]}) =>
      helper.completeCashTransaction(items: items, amountPaid: 100000);

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    directory = await Directory.systemTemp.createTemp('identity-migration-');
    await databaseFactory.setDatabasesPath(directory.path);
    // Fixture schema v4, sebelum ada kolom identitas. Buka kembali melalui helper produksi.
    final legacy = await openDatabase(
      path.join(directory.path, 'kasir.db'),
      version: 4,
      onCreate: (db, _) async {
        await db.execute('''CREATE TABLE products (
          id INTEGER PRIMARY KEY AUTOINCREMENT, kode TEXT NOT NULL UNIQUE,
          barcode TEXT, nama TEXT NOT NULL, unit TEXT, harga_jual REAL DEFAULT 0,
          stok REAL DEFAULT 0, lokasi TEXT, aktif INTEGER DEFAULT 1)''');
        await db.execute(
          'CREATE INDEX idx_products_barcode ON products(barcode)',
        );
        await db.execute(
          'CREATE INDEX idx_products_nama_id ON products(nama, id)',
        );
        await db.execute('''CREATE TABLE transactions (
          id INTEGER PRIMARY KEY AUTOINCREMENT, transaction_no TEXT NOT NULL UNIQUE,
          transaction_date TEXT NOT NULL, total INTEGER NOT NULL, payment_method TEXT NOT NULL,
          amount_paid INTEGER NOT NULL, change_amount INTEGER NOT NULL,
          status TEXT NOT NULL DEFAULT 'COMPLETED')''');
        await db.execute('''CREATE TABLE transaction_items (
          id INTEGER PRIMARY KEY AUTOINCREMENT, transaction_id INTEGER NOT NULL,
          product_id INTEGER NOT NULL, kode TEXT NOT NULL, barcode TEXT, nama TEXT NOT NULL,
          unit TEXT, price INTEGER NOT NULL, qty INTEGER NOT NULL, subtotal INTEGER NOT NULL,
          FOREIGN KEY (transaction_id) REFERENCES transactions(id))''');
        await db.execute(
          'CREATE INDEX idx_transaction_items_transaction_id ON transaction_items(transaction_id)',
        );
        await db.execute(
          'CREATE INDEX idx_transactions_date_id ON transactions(transaction_date DESC, id DESC)',
        );
      },
    );
    await legacy.insert('products', {
      'id': 1,
      'kode': 'A',
      'nama': 'Apel',
      'harga_jual': 1000,
      'stok': 10,
    });
    await legacy.insert('transactions', {
      'id': 1,
      'transaction_no': 'TRX-LEGACY',
      'transaction_date': DateTime.now().toUtc().toIso8601String(),
      'total': 1000,
      'payment_method': 'CASH',
      'amount_paid': 1000,
      'change_amount': 0,
    });
    await legacy.insert('transaction_items', {
      'id': 1,
      'transaction_id': 1,
      'product_id': 1,
      'kode': 'A',
      'nama': 'Apel',
      'price': 1000,
      'qty': 1,
      'subtotal': 1000,
    });
    oldTransactions = await legacy.query('transactions');
    oldItems = await legacy.query('transaction_items');
    oldProducts = await legacy.query('products');
    await legacy.close();
    // Setting sekarang tidak boleh digunakan untuk backfill.
    SharedPreferences.setMockInitialValues({});
    await SettingsService().save(outletCode: 'KWD', terminalCode: 'TERM-01');
    db = await helper.database;
    migratedProducts = await db.query('products');
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await db.delete('transaction_items', where: 'transaction_id != 1');
    await db.delete('transactions', where: 'id != 1');
    await db.update('products', {'stok': 10}, where: 'id = 1');
  });
  tearDownAll(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'Migration v4 ke v5 mempertahankan header/item/master dan NULL legacy',
    () async {
      expect(await db.getVersion(), 5);
      expect(migratedProducts, oldProducts);
      expect(await helper.getTransactionById(1), {
        ...oldTransactions.single,
        'outlet_code': null,
        'terminal_code': null,
      });
      expect(await helper.getTransactionItems(1), oldItems);
      expect(await db.query('products'), oldProducts);
      final columns = await db.rawQuery('PRAGMA table_info(transactions)');
      expect(columns.length, oldTransactions.single.length + 2);
      for (final name in ['outlet_code', 'terminal_code']) {
        expect(columns.singleWhere((c) => c['name'] == name)['notnull'], 0);
      }
      expect(
        (await helper.getTransactions()).single['transaction_no'],
        'TRX-LEGACY',
      );
    },
  );

  test(
    'Snapshot tetap saat setting diganti; transaksi berikutnya memakai setting baru',
    () async {
      await SettingsService().save(outletCode: 'SMR', terminalCode: 'TERM-02');
      await complete();
      await SettingsService().save(outletCode: 'KWD', terminalCode: 'TERM-01');
      await complete();
      final rows = await db.query('transactions', orderBy: 'id');
      expect(rows[1]['outlet_code'], 'SMR');
      expect(rows[1]['terminal_code'], 'TERM-02');
      expect(rows[2]['outlet_code'], 'KWD');
      expect(rows[2]['terminal_code'], 'TERM-01');
      expect(rows[0]['outlet_code'], isNull);
      expect(
        (await helper.getDailySalesReport(
          DateTime.now(),
        )).summary['total_sales'],
        5000,
      );
      expect(await helper.countTransactions(), 3);
    },
  );

  test(
    'Konfigurasi kosong/parsial ditolak tanpa insert atau pengurangan stok',
    () async {
      for (final values in <Map<String, Object>>[
        {},
        {'cashier_identity': '{"outletCode":"KWD"}'},
        {'cashier_identity': '{"terminalCode":"TERM-01"}'},
      ]) {
        SharedPreferences.setMockInitialValues(values);
        await expectLater(
          complete(),
          throwsA(isA<MissingCashierIdentityException>()),
        );
        expect(await db.query('transactions'), [
          {
            ...oldTransactions.single,
            'outlet_code': null,
            'terminal_code': null,
          },
        ]);
        expect(await db.query('transaction_items'), oldItems);
        expect(await db.query('products'), oldProducts);
      }
    },
  );

  test(
    'Kegagalan stok rollback dan nomor duplikat tidak mengurangi stok lagi',
    () async {
      await SettingsService().save(outletCode: 'KWD', terminalCode: 'TERM-01');
      await expectLater(
        complete(
          items: [
            item,
            const TransactionItem(
              productId: 99,
              kode: 'MISSING',
              nama: 'Tidak ada',
              price: 100,
              qty: 1,
            ),
          ],
        ),
        throwsA(isA<InsufficientStockException>()),
      );
      expect(await helper.countTransactions(), 1);
      expect(await db.query('transaction_items'), oldItems);
      expect(await db.query('products'), oldProducts);
      final receipt = await complete();
      final saved = (await db.query(
        'transactions',
        where: 'transaction_no = ?',
        whereArgs: [receipt.transactionNo],
      )).single;
      await expectLater(
        db.insert('transactions', {...saved}..remove('id')),
        throwsA(isA<DatabaseException>()),
      );
      expect((await helper.getProductByKode('A'))!['stok'], 8);
      expect(await helper.countTransactions(), 2);
    },
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Detail memakai snapshot baru dan aman untuk NULL legacy', (
    tester,
  ) async {
    await SettingsService().save(outletCode: 'KWD', terminalCode: 'TERM-01');
    final receipt = await complete();
    final row = (await db.query(
      'transactions',
      where: 'transaction_no = ?',
      whereArgs: [receipt.transactionNo],
    )).single;
    await SettingsService().save(outletCode: 'DKO', terminalCode: 'TERM-02');
    await tester.pumpWidget(
      MaterialApp(home: TransactionDetailPage(transactionId: row['id'] as int)),
    );
    await settle(tester);
    expect(find.text('Outlet: Kawedusan (KWD)'), findsOneWidget);
    expect(find.text('Terminal: TERM-01'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(
      const MaterialApp(home: TransactionDetailPage(transactionId: 1)),
    );
    await settle(tester);
    expect(find.text('Outlet: Tidak tersedia'), findsOneWidget);
    expect(find.text('Terminal: Tidak tersedia'), findsOneWidget);
    expect(find.text('Apel'), findsOneWidget);
  });

  testWidgets('Pembayaran ditolak memberi pesan dan mempertahankan keranjang', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: TransactionPage()));
    await tester.enterText(find.byType(TextField), 'A');
    await tester.tap(find.byTooltip('Tambah barang'));
    await settle(tester);
    expect(find.text('Apel'), findsOneWidget);
    await tester.tap(find.text('Bayar'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Uang Diterima'),
      '1000',
    );
    await tester.pump();
    await tester.tap(find.text('Selesaikan Transaksi'));
    await settle(tester);
    expect(
      find.text(const MissingCashierIdentityException().toString()),
      findsOneWidget,
    );
    await tester.tap(find.text('Kembali ke Keranjang'));
    await tester.pumpAndSettle();
    expect(find.text('Apel'), findsOneWidget);
    expect(find.text('Qty: 1'), findsOneWidget);
    expect(find.text('TOTAL: Rp 1.000'), findsOneWidget);
    expect(await helper.countTransactions(), 1);
    expect(await db.query('transaction_items'), oldItems);
    expect(await db.query('products'), oldProducts);
  });
}
