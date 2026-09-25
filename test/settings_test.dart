import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasir_app/main.dart';
import 'package:kasir_app/models/outlet.dart';
import 'package:kasir_app/pages/settings_page.dart';
import 'package:kasir_app/services/settings_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('Master outlet permanen dan terminal tersedia', () {
    expect(
      {for (final o in outlets) o.code: o.name},
      {'DKO': 'Doko', 'SMR': 'Sumberejo', 'GRH': 'Gurah', 'KWD': 'Kawedusan'},
    );
    expect(outlets.every((o) => o.active), isTrue);
    expect(terminalCodes, ['TERM-01', 'TERM-02']);
    const identity = CashierIdentity(
      outletCode: 'KWD',
      terminalCode: 'TERM-01',
    );
    expect(identity.deviceIdentity, 'KWD-TERM-01');
    expect(identity.outlet?.name, 'Kawedusan');
  });

  test('Belum disimpan tidak memiliki default', () async {
    expect(await SettingsService().load(), isNull);
  });

  test(
    'Validasi menolak pilihan kosong atau tidak dikenal tanpa menyimpan',
    () async {
      final service = SettingsService();
      for (final pair in [
        (null, null),
        ('DKO', null),
        (null, 'TERM-01'),
        ('INVALID', 'TERM-01'),
        ('DKO', 'TERM-99'),
      ]) {
        await expectLater(
          service.save(outletCode: pair.$1, terminalCode: pair.$2),
          throwsArgumentError,
        );
      }
      expect(await service.load(), isNull);
    },
  );

  test(
    'Simpan dan baca ulang hanya menyimpan kode, perubahan langsung aktif',
    () async {
      await SettingsService().save(outletCode: 'SMR', terminalCode: 'TERM-02');
      final prefs = await SharedPreferences.getInstance();
      await prefs.reload();
      expect((await SettingsService().load())?.deviceIdentity, 'SMR-TERM-02');
      await SettingsService().save(outletCode: 'KWD', terminalCode: 'TERM-01');
      await prefs.reload();
      expect((await SettingsService().load())?.deviceIdentity, 'KWD-TERM-01');
      expect(jsonDecode(prefs.getString('cashier_identity')!), {
        'outletCode': 'KWD',
        'terminalCode': 'TERM-01',
      });
    },
  );

  testWidgets('Home membuka Pengaturan dan validasi pilihan belum lengkap', (
    tester,
  ) async {
    await tester.pumpWidget(const KasirApp());
    await tester.ensureVisible(find.text('Pengaturan'));
    await tester.tap(find.text('Pengaturan'));
    await tester.pumpAndSettle();
    expect(find.byType(SettingsPage), findsOneWidget);
    expect(find.text('Belum dipilih'), findsOneWidget);
    await tester.tap(find.text('SIMPAN PENGATURAN'));
    await tester.pumpAndSettle();
    expect(find.text('Pilih outlet aktif terlebih dahulu.'), findsOneWidget);
    expect(find.text('Pilih terminal terlebih dahulu.'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('outlet')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('KWD - Kawedusan').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('SIMPAN PENGATURAN'));
    await tester.tap(find.text('SIMPAN PENGATURAN'));
    await tester.pumpAndSettle();
    expect(find.text('Pilih terminal terlebih dahulu.'), findsOneWidget);
    expect(await SettingsService().load(), isNull);
    await tester.ensureVisible(find.byKey(const ValueKey('terminal')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('terminal')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('TERM-01').last);
    await tester.pumpAndSettle();
    expect(find.text('KWD-TERM-01'), findsOneWidget);
    await tester.ensureVisible(find.text('SIMPAN PENGATURAN'));
    await tester.tap(find.text('SIMPAN PENGATURAN'));
    await tester.pumpAndSettle();
    expect(find.text('Pengaturan berhasil disimpan.'), findsOneWidget);
    expect((await SettingsService().load())?.deviceIdentity, 'KWD-TERM-01');
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Pengaturan'));
    await tester.pumpAndSettle();
    expect(find.text('KWD-TERM-01'), findsOneWidget);
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey('outlet')),
          )
          .initialValue,
      'KWD',
    );
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const ValueKey('terminal')),
          )
          .initialValue,
      'TERM-01',
    );
  });

  testWidgets('Pilihan tersimpan dimuat pada layar kecil dengan teks besar', (
    tester,
  ) async {
    await SettingsService().save(outletCode: 'SMR', terminalCode: 'TERM-02');
    tester.view.physicalSize = const Size(320, 568);
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
        home: const SettingsPage(),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('SMR-TERM-02'), findsOneWidget);
    await tester.ensureVisible(find.text('SIMPAN PENGATURAN'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
