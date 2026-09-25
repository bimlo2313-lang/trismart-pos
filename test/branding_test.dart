import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasir_app/main.dart';

void main() {
  testWidgets(
    'Splash tetap terlihat 1500 ms meski initialization sudah selesai',
    (tester) async {
      await tester.pumpWidget(KasirApp(initialization: Future<void>.value()));
      expect(find.byType(DashboardPage), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsNothing);
      final splash = tester.widget<Image>(find.byType(Image));
      expect(splash.fit, BoxFit.contain);
      expect(
        (splash.image as AssetImage).assetName,
        'assets/branding/splash_trismart.png',
      );
      await tester.pump(const Duration(milliseconds: 1499));
      expect(find.byType(DashboardPage), findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byType(DashboardPage), findsOneWidget);
      expect(
        Navigator.of(tester.element(find.byType(DashboardPage))).canPop(),
        isFalse,
      );
    },
  );

  testWidgets('Initialization lambat tetap ditunggu setelah minimum splash', (
    tester,
  ) async {
    final initialization = Completer<void>();
    await tester.pumpWidget(KasirApp(initialization: initialization.future));
    await tester.pump(const Duration(milliseconds: 1500));
    expect(find.byType(DashboardPage), findsNothing);
    initialization.complete();
    await tester.pump();
    // Future.wait menyelesaikan agregasi sebelum FutureBuilder meminta frame.
    await tester.pump();
    expect(find.byType(DashboardPage), findsOneWidget);
  });

  testWidgets('Melepas splash membatalkan timer dengan aman', (tester) async {
    await tester.pumpWidget(KasirApp(initialization: Future<void>.value()));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 1500));
    expect(tester.takeException(), isNull);
  });

  for (final size in [
    const Size(320, 568),
    const Size(240, 400),
    const Size(900, 600),
  ]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('Dashboard tanpa overflow: $size, teks $scale', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
            home: const DashboardPage(),
          ),
        );
        await tester.pumpAndSettle();
        for (final label in [
          'Transaksi',
          'Data Barang',
          'Riwayat',
          'Laporan',
          'Pengaturan',
        ]) {
          expect(find.text(label), findsOneWidget);
        }
        await tester.ensureVisible(find.text('Developed By Bimz'));
        await tester.pumpAndSettle();
        expect(find.text('Developed By Bimz'), findsOneWidget);
        expect(find.text('IT SUPPORT'), findsOneWidget);
        expect(find.text('Cepat • Mudah • Terpercaya'), findsOneWidget);
        final settingsCard = find.ancestor(
          of: find.text('Pengaturan'),
          matching: find.byType(Card),
        );
        expect(
          tester.getBottomLeft(settingsCard).dy,
          lessThan(tester.getTopLeft(find.text('Developed By Bimz')).dy),
        );
        for (final label in ['Pengaturan']) {
          final ink = tester.widget<InkWell>(
            find.ancestor(of: find.text(label), matching: find.byType(InkWell)),
          );
          expect(ink.onTap, isNotNull);
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
}
