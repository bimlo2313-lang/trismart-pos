import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasir_app/database/database_helper.dart';
import 'package:kasir_app/pages/transaction_page.dart';
import 'package:kasir_app/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final helper = DatabaseHelper.instance;
  late Directory directory;
  late Database db;

  setUpAll(() async {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfiNoIsolate;
    directory = await Directory.systemTemp.createTemp('name-search-');
    await databaseFactory.setDatabasesPath(directory.path);
    db = await helper.database;
  });
  tearDownAll(() async {
    await db.close();
    await directory.delete(recursive: true);
  });
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await db.delete('transaction_items');
    await db.delete('transactions');
    await db.delete('products');
    await db.insert('products', {
      'id': 1,
      'kode': '1001',
      'barcode': '0123456789',
      'nama': 'AQUA 600 ML',
      'unit': 'BTL',
      'harga_jual': 3500,
      'stok': 24,
    });
    await db.insert('products', {
      'id': 2,
      'kode': '1002',
      'nama': 'Indomie Goreng',
      'harga_jual': 3000,
      'stok': 0,
    });
    await db.insert('products', {
      'id': 3,
      'kode': '1003',
      'nama': 'AQUA INACTIVE',
      'aktif': 0,
    });
  });

  Future<List<Map<String, dynamic>>> search(String value, {int limit = 20}) =>
      helper.searchProducts(value, transactionNameSearch: true, limit: limit);

  test('SQLite partial, case insensitive, active-only and name-only', () async {
    expect((await search('qUa 600')).single['id'], 1);
    expect((await search('aqua')).map((p) => p['id']), [1]);
    expect(await search('1001'), isEmpty);
    expect(await search('012345'), isEmpty);
    expect(await db.getVersion(), 5);
  });
  test('SQLite clamps maximum 20 and orders equal names by id', () async {
    for (var i = 4; i < 35; i++) {
      await db.insert('products', {'id': i, 'kode': '$i', 'nama': 'AQUA'});
    }
    final rows = await search('aqua', limit: 1000);
    expect(rows.length, 20);
    expect(rows.map((p) => p['id']), List.generate(20, (i) => i + 4));
    expect(await search('aqua', limit: 1000), rows);
  });
  test('Empty, short, no result and escaped LIKE literals', () async {
    expect(await search(' '), isEmpty);
    expect(await search('a'), isEmpty);
    expect(await search('missing'), isEmpty);
    expect(await search('a%'), isEmpty);
    expect(await search('a_'), isEmpty);
    await db.insert('products', {'kode': 'literal', 'nama': r'A%_\B'});
    expect((await search(r'%_\')).single['kode'], 'literal');
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 10)),
      );
      await tester.pump();
    }
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: TransactionPage()));
  }

  Future<void> typeName(WidgetTester tester, String name) async {
    await tester.enterText(find.byType(TextField).first, name);
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
  }

  final result1 = find.byKey(const ValueKey('name-result-1'));
  final result2 = find.byKey(const ValueKey('name-result-2'));

  testWidgets('Debounce, candidate details, selection and focus', (
    tester,
  ) async {
    await mount(tester);
    await tester.enterText(find.byType(TextField), 'aqua');
    await tester.pump(const Duration(milliseconds: 299));
    expect(result1, findsNothing);
    await tester.pump(const Duration(milliseconds: 1));
    await settle(tester);
    expect(result1, findsOneWidget);
    expect(
      find.textContaining('PLU 1001 • Barcode 0123456789'),
      findsOneWidget,
    );
    expect(find.textContaining('Rp 3.500 • Stok 24.0 BTL'), findsOneWidget);
    expect(find.text('AQUA INACTIVE'), findsNothing);
    await tester.tap(result1);
    await settle(tester);
    expect(result1, findsNothing);
    expect(find.text('Qty: 1'), findsOneWidget);
    final input = tester.widget<TextField>(find.byType(TextField));
    expect(input.controller!.text, isEmpty);
    expect(input.focusNode!.hasFocus, isTrue);
  });

  for (final code in ['0123456789', '123456789', '1001']) {
    testWidgets('Exact $code adds before name debounce', (tester) async {
      await mount(tester);
      await tester.enterText(find.byType(TextField), code);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await settle(tester);
      expect(find.text('Qty: 1'), findsOneWidget);
      expect(result1, findsNothing);
    });
  }
  testWidgets('Alphabetic exact code wins over matching names', (tester) async {
    await db.update('products', {'kode': 'aqua'}, where: 'id = 2');
    await mount(tester);
    await typeName(tester, 'aqua');
    expect(result1, findsNothing);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(find.text('Indomie Goreng'), findsOneWidget);
    expect(find.text('Qty: 1'), findsOneWidget);
  });
  testWidgets('Empty, short and no-result feedback', (tester) async {
    await mount(tester);
    await typeName(tester, 'missing');
    expect(find.text('Barang tidak ditemukan'), findsOneWidget);
    await typeName(tester, '');
    expect(find.text('Barang tidak ditemukan'), findsNothing);
    expect(find.byType(ListTile), findsNothing);
    await typeName(tester, 'a');
    expect(find.byType(ListTile), findsNothing);
  });
  testWidgets('New input invalidates in-flight search and old debounce', (
    tester,
  ) async {
    await mount(tester);
    await tester.enterText(find.byType(TextField), 'aqua');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.enterText(find.byType(TextField), 'indomie');
    await settle(tester);
    expect(result1, findsNothing);
    expect(result2, findsNothing);
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
    expect(result2, findsOneWidget);
    expect(find.textContaining('Barcode'), findsOneWidget); // Input label only.
    await tester.enterText(find.byType(TextField), 'aqua');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(find.byType(TextField), '');
    await tester.pump(const Duration(milliseconds: 300));
    await settle(tester);
    expect(find.byType(ListTile), findsNothing);
  });
  testWidgets('Submit name searches immediately; selection uses PLU identity', (
    tester,
  ) async {
    await db.update('products', {'barcode': '1001'}, where: 'id = 2');
    await mount(tester);
    await tester.enterText(find.byType(TextField), 'aqua');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settle(tester);
    expect(result1, findsOneWidget);
    await tester.tap(result1);
    await settle(tester);
    expect(find.text('AQUA 600 ML'), findsOneWidget);
    expect(find.text('Indomie Goreng'), findsNothing);
  });
  testWidgets('Rapid USB submits retain every scan without suggestions', (
    tester,
  ) async {
    await mount(tester);
    for (var i = 0; i < 5; i++) {
      await tester.enterText(find.byType(TextField), '123456789');
      await tester.testTextInput.receiveAction(TextInputAction.done);
    }
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('Qty: 5'), findsOneWidget);
    expect(find.byType(ListTile), findsNothing);
  });
  testWidgets('Zero-stock candidate follows existing payment validation', (
    tester,
  ) async {
    await SettingsService().save(outletCode: 'KWD', terminalCode: 'TERM-01');
    await mount(tester);
    await typeName(tester, 'indomie');
    await tester.tap(result2);
    await settle(tester);
    expect(find.text('Qty: 1'), findsOneWidget);
    await tester.tap(find.text('Bayar'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Uang Diterima'),
      '3000',
    );
    await tester.pump();
    await tester.tap(find.text('Selesaikan Transaksi'));
    await settle(tester);
    expect(find.textContaining('Stok'), findsWidgets);
    expect(await db.query('transactions'), isEmpty);
    expect((await helper.getProductByKode('1002'))!['stok'], 0);
  });
}
