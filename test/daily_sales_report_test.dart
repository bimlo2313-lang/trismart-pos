import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasir_app/database/database_helper.dart';
import 'package:kasir_app/main.dart';
import 'package:kasir_app/pages/daily_sales_report_page.dart';
import 'package:kasir_app/pages/transaction_detail_page.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseHelper.instance;
  late Database db;
  late Directory directory;
  final day = DateTime(2026, 9, 25);

  Future<int> seed(
    DateTime date, {
    String status = 'COMPLETED',
    int qty = 2,
    int price = 1000,
    String kode = 'A',
    String nama = 'Apel',
  }) async {
    final id = await db.insert('transactions', {
      'transaction_no': 'TRX-${date.microsecondsSinceEpoch}-$kode-$status',
      'transaction_date': date.toUtc().toIso8601String(),
      'total': qty * price,
      'payment_method': 'CASH',
      'amount_paid': qty * price,
      'change_amount': 0,
      'status': status,
    });
    await db.insert('transaction_items', {
      'transaction_id': id,
      'product_id': 1,
      'kode': kode,
      'nama': nama,
      'price': price,
      'qty': qty,
      'subtotal': qty * price,
    });
    return id;
  }

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    directory = await Directory.systemTemp.createTemp('daily-report-test-');
    await databaseFactory.setDatabasesPath(directory.path);
    db = await helper.database;
  });
  setUp(() async {
    await db.delete('transaction_items');
    await db.delete('transactions');
  });
  tearDownAll(() async {
    await db.close();
    await directory.delete(recursive: true);
  });

  test(
    'Hanya COMPLETED dalam hari lokal termasuk batas tengah malam',
    () async {
      await seed(day.subtract(const Duration(microseconds: 1)));
      await seed(day);
      await seed(DateTime(2026, 9, 25, 23, 59, 59, 999, 999), qty: 3);
      await seed(DateTime(2026, 9, 26));
      await seed(day, status: 'CANCELLED', qty: 99);
      await seed(day, status: 'PENDING', qty: 88);
      final report = await helper.getDailySalesReport(day);
      expect(report.summary, {
        'transaction_count': 2,
        'total_sales': 5000,
        'total_qty': 5,
        'average_transaction': 2500.0,
      });
      expect(report.transactions.map((row) => row['total_qty']), [3, 2]);
      expect(report.products.single['total_qty'], 5);
      expect(report.products.single['revenue'], 5000);
    },
  );

  test(
    'Snapshot kode/nama, urutan qty lalu nama, total header tidak berlipat',
    () async {
      final id = await seed(day, qty: 3);
      await db.insert('transaction_items', {
        'transaction_id': id,
        'product_id': 2,
        'kode': 'B',
        'nama': 'Beras',
        'price': 500,
        'qty': 2,
        'subtotal': 1000,
      });
      await db.update(
        'transactions',
        {'total': 4000},
        where: 'id = ?',
        whereArgs: [id],
      );
      await seed(day.add(const Duration(hours: 1)), qty: 1, price: 2001);
      await seed(day.add(const Duration(hours: 2)), qty: 2, nama: 'Apel Baru');
      await seed(
        day.add(const Duration(hours: 3)),
        qty: 2,
        kode: 'C',
        nama: 'Apel',
      );
      final report = await helper.getDailySalesReport(day);
      expect(report.summary['transaction_count'], 4);
      expect(report.summary['total_sales'], 10001);
      expect(report.summary['average_transaction'], 2500.25);
      expect(report.summary['total_qty'], 10);
      expect(report.products.map((r) => '${r['kode']}:${r['nama']}'), [
        'A:Apel',
        'C:Apel',
        'A:Apel Baru',
        'B:Beras',
      ]);
      expect(report.products.first['revenue'], 5001);
      expect(await db.getVersion(), 5);
    },
  );

  test('Tanggal kosong menghasilkan nol dan daftar kosong', () async {
    final report = await helper.getDailySalesReport(day);
    expect(report.summary.values, everyElement(0));
    expect(report.transactions, isEmpty);
    expect(report.products, isEmpty);
  });

  Future<void> settleDatabase(WidgetTester tester) async {
    await tester.runAsync(() async {
      // Tunggu antrean SQLite dan kelanjutan FutureBuilder selesai.
      await Future<void>.delayed(const Duration(milliseconds: 150));
    });
    await tester.pumpAndSettle();
  }

  testWidgets('Home membuka laporan hari ini dan empty state', (tester) async {
    await seed(DateTime(2020, 1, 2));
    await tester.pumpWidget(const KasirApp());
    await tester.tap(find.text('Laporan'));
    await tester.pump();
    await settleDatabase(tester);
    expect(find.byType(DailySalesReportPage), findsOneWidget);
    expect(
      find.text('Belum ada transaksi selesai pada tanggal ini.'),
      findsOneWidget,
    );
    final now = DateTime.now();
    expect(
      find.text(
        'Tanggal: ${now.day.toString().padLeft(2, '0')}/${now.month.toString().padLeft(2, '0')}/${now.year}',
      ),
      findsOneWidget,
    );
    await tester.tap(find.byIcon(Icons.calendar_month));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.byIcon(Icons.edit_outlined));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextFormField), '01/02/2020');
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
    await settleDatabase(tester);
    expect(find.text('Tanggal: 02/01/2020'), findsOneWidget);
    expect(
      find.text('Belum ada transaksi selesai pada tanggal ini.'),
      findsNothing,
    );
    expect(find.text('Total: Rp 2.000'), findsOneWidget);
  });

  testWidgets('Barang terjual dan tap transaksi membuka detail existing', (
    tester,
  ) async {
    final id = await seed(DateTime.now());
    await tester.pumpWidget(const MaterialApp(home: DailySalesReportPage()));
    await settleDatabase(tester);
    await tester.tap(find.text('BARANG TERJUAL'));
    await tester.pumpAndSettle();
    expect(find.text('Apel'), findsOneWidget);
    expect(find.text('Omzet: Rp 2.000'), findsOneWidget);
    await tester.tap(find.text('TRANSAKSI'));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('TRX-'));
    await settleDatabase(tester);
    expect(
      tester
          .widget<TransactionDetailPage>(find.byType(TransactionDetailPage))
          .transactionId,
      id,
    );
  });

  testWidgets('Laporan responsif pada layar kecil dan teks besar', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(240, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(2)),
          child: child!,
        ),
        home: const DailySalesReportPage(),
      ),
    );
    await settleDatabase(tester);
    await tester.scrollUntilVisible(find.text('BARANG TERJUAL'), 200);
    expect(tester.takeException(), isNull);
  });
}
