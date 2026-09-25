import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasir_app/database/database_helper.dart';
import 'package:kasir_app/models/cash_transaction.dart';
import 'package:kasir_app/pages/cash_payment_dialog.dart';
import 'package:kasir_app/pages/transaction_detail_page.dart';
import 'package:kasir_app/pages/transaction_history_page.dart';
import 'package:kasir_app/pages/daily_sales_report_page.dart';
import 'package:kasir_app/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseHelper.instance;
  late Directory directory;
  late Database db;
  final date = DateTime(2026, 9, 25, 23, 59, 59);
  const item = TransactionItem(
    productId: 1,
    kode: 'A',
    nama: 'Apel',
    price: 1000,
    qty: 1,
  );
  Future<CashReceipt> complete({
    DateTime? at,
    List<TransactionItem> items = const [item],
  }) => helper.completeCashTransaction(
    items: items,
    amountPaid: 100000,
    now: () => at ?? date,
  );
  Future<void> identity(String outlet, String terminal) =>
      SettingsService().save(outletCode: outlet, terminalCode: terminal);
  Future<void> seed(String number) => db.insert('transactions', {
    'transaction_no': number,
    'transaction_date': date.toUtc().toIso8601String(),
    'total': 0,
    'payment_method': 'CASH',
    'amount_paid': 0,
    'change_amount': 0,
  });

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    directory = await Directory.systemTemp.createTemp('transaction-number-');
    await databaseFactory.setDatabasesPath(directory.path);
    db = await helper.database;
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await identity('KWD', 'TERM-01');
    await db.delete('transaction_items');
    await db.delete('transactions');
    await db.delete('products');
    await db.insert('products', {
      'id': 1,
      'kode': 'A',
      'nama': 'Apel',
      'stok': 100,
      'harga_jual': 1000,
    });
  });
  tearDownAll(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test('Urutan pertama/kedua dan timestamp memakai satu waktu lokal', () async {
    expect((await complete()).transactionNo, 'KWD-01-20260925-000001');
    expect((await complete()).transactionNo, 'KWD-01-20260925-000002');
    final rows = await db.query('transactions');
    expect(rows.first['transaction_date'], date.toUtc().toIso8601String());
    expect(rows.first['outlet_code'], 'KWD');
    expect(rows.first['terminal_code'], 'TERM-01');
    expect(await db.getVersion(), 5);
  });

  test('Urutan terpisah per terminal, outlet, dan tanggal lokal', () async {
    await complete();
    await identity('KWD', 'TERM-02');
    expect((await complete()).transactionNo, 'KWD-02-20260925-000001');
    await identity('SMR', 'TERM-01');
    expect((await complete()).transactionNo, 'SMR-01-20260925-000001');
    await identity('KWD', 'TERM-01');
    expect(
      (await complete(at: DateTime(2026, 9, 26))).transactionNo,
      'KWD-01-20260926-000001',
    );
    expect((await complete()).transactionNo, 'KWD-01-20260925-000002');
  });

  test(
    'MAX bukan jumlah row; UUID dan format tidak cocok tetap utuh',
    () async {
      for (final number in [
        'TRX-123-abcdef',
        'KWD-01-20260925-999999x',
        'KWD-01-20260925-1234567',
        'KWD-01-20260925-99999',
        'KWD-01-20260925-ABCDEF',
        'KWD-01-20260925-000009',
      ]) {
        await seed(number);
      }
      final before = await db.query('transactions', orderBy: 'id');
      expect((await complete()).transactionNo, 'KWD-01-20260925-000010');
      expect(
        (await db.query('transactions', orderBy: 'id')).take(before.length),
        before,
      );
    },
  );

  test('Finalisasi bersamaan menghasilkan nomor unik berurutan', () async {
    final receipts = await Future.wait(List.generate(5, (_) => complete()));
    expect(receipts.map((r) => r.transactionNo).toSet().length, 5);
    expect(
      (await db.query(
        'transactions',
        orderBy: 'transaction_no',
      )).last['transaction_no'],
      'KWD-01-20260925-000005',
    );
    expect((await helper.getProductByKode('A'))!['stok'], 95);
  });

  test('Rollback setelah update stok tidak menghabiskan sequence', () async {
    await expectLater(
      complete(
        items: [
          item,
          const TransactionItem(
            productId: 99,
            kode: 'X',
            nama: 'Hilang',
            price: 100,
            qty: 1,
          ),
        ],
      ),
      throwsA(isA<InsufficientStockException>()),
    );
    expect(await helper.countTransactions(), 0);
    expect(await db.query('transaction_items'), isEmpty);
    expect((await helper.getProductByKode('A'))!['stok'], 100);
    expect((await complete()).transactionNo, 'KWD-01-20260925-000001');
  });

  test('UNIQUE collision saat INSERT rollback seluruh finalisasi', () async {
    // Trigger khusus fixture menyisipkan nomor sama sesaat sebelum INSERT produksi.
    await db.execute(
      '''CREATE TEMP TRIGGER force_collision BEFORE INSERT ON transactions
      BEGIN INSERT INTO transactions (transaction_no, transaction_date, total, payment_method, amount_paid, change_amount)
      VALUES (NEW.transaction_no, NEW.transaction_date, 0, 'CASH', 0, 0); END''',
    );
    try {
      await expectLater(complete(), throwsA(isA<DatabaseException>()));
      expect(await helper.countTransactions(), 0);
      expect(await db.query('transaction_items'), isEmpty);
      expect((await helper.getProductByKode('A'))!['stok'], 100);
    } finally {
      await db.execute('DROP TRIGGER force_collision');
    }
    expect((await complete()).transactionNo, 'KWD-01-20260925-000001');
  });

  test('Batas enam digit ditolak tanpa perubahan data', () async {
    await seed('KWD-01-20260925-999999');
    await expectLater(complete(), throwsStateError);
    expect(await helper.countTransactions(), 1);
    expect((await helper.getProductByKode('A'))!['stok'], 100);
  });

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 150)),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('Pembayaran double-submit tetap hanya menyimpan sekali', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: CashPaymentDialog(items: [item])),
      ),
    );
    await tester.enterText(find.byType(TextField), '1000');
    await tester.pump();
    await tester.tap(find.text('Selesaikan Transaksi'));
    await tester.tap(find.text('Selesaikan Transaksi'));
    await settle(tester);
    expect(find.text('Transaksi Berhasil'), findsOneWidget);
    expect(await helper.countTransactions(), 1);
    expect((await helper.getProductByKode('A'))!['stok'], 99);
  });

  testWidgets('Nomor baru aman di History, Detail, dan Laporan layar kecil', (
    tester,
  ) async {
    final receipt = await complete(at: DateTime.now());
    final id = (await db.query('transactions')).single['id'] as int;
    tester.view.physicalSize = const Size(320, 568);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    for (final page in <Widget>[
      const TransactionHistoryPage(),
      TransactionDetailPage(transactionId: id),
      const DailySalesReportPage(),
    ]) {
      await tester.pumpWidget(const SizedBox());
      await tester.pumpWidget(MaterialApp(home: page));
      await settle(tester);
      await tester.scrollUntilVisible(
        find.text(receipt.transactionNo),
        150,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text(receipt.transactionNo), findsOneWidget);
      expect(tester.takeException(), isNull);
    }
  });
}
