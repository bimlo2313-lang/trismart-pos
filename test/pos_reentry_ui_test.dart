import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasir_app/pages/pos_reentry_page.dart';

void main() {
  List<Map<String, dynamic>> items() => [
    {
      'nama': 'CRYSTALLINE PET 600 ML',
      'qty': 2,
      'kode': '1010787',
      'barcode': '08991102026352',
      'price': 12200,
      'subtotal': 24400,
    },
    {
      'nama': 'Barang tanpa barcode',
      'qty': 1,
      'kode': '1130810',
      'barcode': '',
      'price': 5000,
      'subtotal': 5000,
    },
  ];

  testWidgets('Snapshot barcode, fallback PLU, navigasi dan progress lokal', (
    tester,
  ) async {
    final snapshot = items();
    await tester.pumpWidget(
      MaterialApp(
        home: PosReentryPage(
          transactionNo: 'TRX-long-uuid-6974a913',
          items: snapshot,
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('CRYSTALLINE PET 600 ML'), findsOneWidget);
    expect(find.text('Qty'), findsOneWidget);
    expect(find.text('2'), findsOneWidget);
    expect(find.text('1010787'), findsOneWidget);
    expect(find.text('Transaksi  ...6974a913'), findsOneWidget);
    expect(
      tester.widget<BarcodeWidget>(find.byType(BarcodeWidget)).data,
      '08991102026352'.codeUnits,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'Sebelumnya'),
          )
          .onPressed,
      isNull,
    );
    await tester.tap(find.byType(CheckboxListTile));
    await tester.pump();
    expect(find.text('1 dari 2 diproses'), findsOneWidget);
    await tester.tap(find.text('Berikutnya'));
    await tester.pumpAndSettle();
    expect(find.text('Barang tanpa barcode'), findsOneWidget);
    expect(find.text('PLU • Barcode tidak tersedia'), findsOneWidget);
    expect(find.text('Menggunakan PLU: 1130810'), findsNothing);
    expect(
      tester.widget<BarcodeWidget>(find.byType(BarcodeWidget)).data,
      '1130810'.codeUnits,
    );
    expect(snapshot[1]['barcode'], '');
    await tester.tap(find.text('Selesai'));
    await tester.pumpAndSettle();
    expect(find.text('Masih ada barang belum diproses'), findsOneWidget);
    await tester.tap(find.text('Lanjutkan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sebelumnya'));
    await tester.pumpAndSettle();
    expect(
      tester.widget<CheckboxListTile>(find.byType(CheckboxListTile)).value,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await tester.pumpAndSettle();
  });

  for (final size in [
    const Size(360, 640),
    const Size(360, 720),
    const Size(393, 852),
    const Size(412, 915),
  ]) {
    for (final fallback in [false, true]) {
      testWidgets('Satu layar $size, nama panjang, fallback=$fallback', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final data = items();
        data[0]['nama'] =
            'NAMA BARANG SANGAT PANJANG UNTUK MEMASTIKAN BATAS DUA BARIS TETAP MENJAGA BARCODE UTUH';
        if (fallback) data[0]['barcode'] = '';
        final value = fallback ? '1010787' : '08991102026352';
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(padding: const EdgeInsets.only(top: 24, bottom: 24)),
              child: child!,
            ),
            home: PosReentryPage(transactionNo: 'TRX-6974a913', items: data),
          ),
        );
        await tester.pumpAndSettle();
        // Tidak melakukan ensureVisible/scroll: semua harus terlihat sejak frame pertama.
        expect(find.byType(SingleChildScrollView), findsNothing);
        final visible = [
          find.text(data[0]['nama'] as String),
          find.text('Qty'),
          find.text('2'),
          find.text('PLU'),
          find.byType(BarcodeWidget),
          find.text(value),
          find.byType(CheckboxListTile),
          find.text('0 dari 2 diproses'),
          find.widgetWithText(OutlinedButton, 'Sebelumnya'),
          find.widgetWithText(FilledButton, 'Berikutnya'),
          find.text(fallback ? 'PLU • Barcode tidak tersedia' : 'BARCODE'),
        ];
        for (final finder in visible) {
          for (final element in finder.evaluate()) {
            final rect = tester.getRect(
              find.byElementPredicate((e) => e == element),
            );
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(size.width));
            expect(rect.top, greaterThanOrEqualTo(24));
            expect(rect.bottom, lessThanOrEqualTo(size.height - 24));
          }
          expect(finder, findsWidgets);
        }
        final name = tester.widget<Text>(find.text(data[0]['nama'] as String));
        expect(name.maxLines, 2);
        expect(name.overflow, TextOverflow.ellipsis);
        final bars = tester.getRect(find.byType(BarcodeWidget));
        expect(bars.left, greaterThanOrEqualTo(24));
        expect(bars.right, lessThanOrEqualTo(size.width - 24));
        expect(bars.height, greaterThanOrEqualTo(55));
        expect(bars.height, lessThanOrEqualTo(145));
        expect(find.text('Barcode: $value'), findsNothing);
        expect(find.text('Menggunakan PLU: $value'), findsNothing);
        expect(
          tester.getRect(find.text('Rp 12.200')).right,
          tester.getRect(find.text('Rp 24.400')).right,
        );
        expect(
          bars.bottom,
          lessThan(tester.getTopLeft(find.byType(CheckboxListTile)).dy),
        );
        expect(
          tester.widget<BarcodeWidget>(find.byType(BarcodeWidget)).data,
          value.codeUnits,
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await tester.pumpAndSettle();
      });
    }
  }

  for (final size in [
    const Size(360, 640),
    const Size(320, 480),
    const Size(800, 600),
  ]) {
    testWidgets('Konten scroll aman pada $size', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        MaterialApp(
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(1.5)),
            child: child!,
          ),
          home: PosReentryPage(transactionNo: 'TRX-6974a913', items: items()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(BarcodeWidget));
      await tester.pumpAndSettle();
      expect(
        tester.getBottomLeft(find.byType(BarcodeWidget)).dy,
        lessThanOrEqualTo(tester.getTopLeft(find.byType(CheckboxListTile)).dy),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
    });
  }
}
