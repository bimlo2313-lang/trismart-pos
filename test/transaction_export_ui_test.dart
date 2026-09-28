import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasir_app/pages/backup_section.dart';
import 'package:kasir_app/services/backup_service.dart';
import 'package:kasir_app/services/data_transfer_lock.dart';
import 'package:kasir_app/services/transaction_export_service.dart';
import 'package:kasir_app/utils/transaction_date_format.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Exporter extends TransactionExportService {
  final calls = <({DateTime start, DateTime end})>[];
  final results = <_Result>[];
  Object? error;

  @override
  Future<TransactionExportResult> export({
    required DateTime startDate,
    required DateTime endDate,
  }) async {
    calls.add((start: startDate, end: endDate));
    if (error != null) throw error!;
    final result = _Result(startDate, endDate);
    results.add(result);
    return result;
  }
}

// Track UI ownership without duplicating the engine's filesystem cleanup tests.
class _Result extends TransactionExportResult {
  _Result(DateTime start, DateTime end)
    : super(
        file: File('unused-export.zip'),
        filename: 'unused-export.zip',
        directory: Directory('unused-export'),
        startDate: start,
        endDate: end,
        transactionCount: 3,
        itemCount: 5,
      );

  int disposals = 0;
  Completer<void>? cleanup;

  @override
  Future<void> dispose() async {
    disposals++;
    await cleanup?.future;
  }
}

void main() {
  final now = DateTime(2026, 9, 28, 14, 35);
  final today = DateTime(2026, 9, 28);
  final metadata = <String, dynamic>{
    'created_at': '2026-09-20T03:45:30.000Z',
    'outlet_code': 'KWD',
    'terminal_code': 'TERM-01',
    'transaction_count': 17,
  };
  late _Exporter exporter;
  late Future<bool> Function(TransactionExportResult) save;
  late int saves;

  setUp(() {
    DataTransferLock.release();
    SharedPreferences.setMockInitialValues({
      'last_successful_backup': jsonEncode(metadata),
    });
    exporter = _Exporter();
    saves = 0;
    save = (_) async => true;
  });
  tearDown(DataTransferLock.release);

  Future<void> mount(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1000, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BackupSection(
              exportService: exporter,
              now: () => now,
              saveExport: (result) {
                saves++;
                expectSync(DataTransferLock.acquire(), isFalse);
                return save(result);
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> select(WidgetTester tester, String label) async {
    await tester.tap(find.byType(DropdownButtonFormField<ExportPeriod>));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  Future<void> export(WidgetTester tester) async {
    await tester.tap(find.text('EXPORT'));
    await tester.pumpAndSettle();
  }

  Future<void> date(WidgetTester tester, String label, int day) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOneWidget);
    await tester.tap(find.text('$day').last);
    await tester.tap(find.text('OK'));
    await tester.pumpAndSettle();
  }

  void released() {
    expect(DataTransferLock.acquire(), isTrue);
    DataTransferLock.release();
  }

  void available(WidgetTester tester) {
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'BUAT BACKUP'),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<OutlinedButton>(
            find.widgetWithText(OutlinedButton, 'PULIHKAN DARI BACKUP'),
          )
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'EXPORT'))
          .onPressed,
      isNotNull,
    );
  }

  testWidgets('Default Hari Ini dan Backup/Restore tersedia', (tester) async {
    await mount(tester);
    expect(
      tester
          .widget<DropdownButton<ExportPeriod>>(
            find.byType(DropdownButton<ExportPeriod>),
          )
          .value,
      ExportPeriod.today,
    );
    available(tester);
    await export(tester);
    expect(exporter.calls.single, (start: today, end: today));
  });

  final presets = <String, ({DateTime start, DateTime end})>{
    'Hari Ini': (start: today, end: today),
    'Kemarin': (start: DateTime(2026, 9, 27), end: DateTime(2026, 9, 27)),
    '7 Hari Terakhir': (start: DateTime(2026, 9, 22), end: today),
    'Bulan Ini': (start: DateTime(2026, 9, 1), end: today),
  };
  for (final preset in presets.entries) {
    testWidgets('Preset ${preset.key} mengirim batas tanggal lokal', (
      tester,
    ) async {
      await mount(tester);
      await select(tester, 'Pilih Tanggal');
      await select(tester, preset.key);
      await export(tester);
      expect(exporter.calls, [preset.value]);
      expect(saves, 1);
      expect(exporter.results.single.disposals, 1);
      released();
    });
  }

  testWidgets('Custom rentang valid dikirim ke export', (tester) async {
    await mount(tester);
    await select(tester, 'Pilih Tanggal');
    await date(tester, 'Dari', 10);
    await date(tester, 'Sampai', 20);
    expect(find.text('Dari 10/09/2026 sampai 20/09/2026'), findsOneWidget);
    await export(tester);
    expect(exporter.calls.single, (
      start: DateTime(2026, 9, 10),
      end: DateTime(2026, 9, 20),
    ));
  });

  testWidgets('Custom akhir sebelum mulai ditolak', (tester) async {
    await mount(tester);
    await select(tester, 'Pilih Tanggal');
    await date(tester, 'Dari', 20);
    await date(tester, 'Sampai', 10);
    await export(tester);
    expect(
      find.text('Tanggal akhir tidak boleh sebelum tanggal mulai.'),
      findsOneWidget,
    );
    expect(exporter.calls, isEmpty);
    expect(saves, 0);
    released();
  });

  testWidgets('Custom belum lengkap ditolak', (tester) async {
    await mount(tester);
    await select(tester, 'Pilih Tanggal');
    await export(tester);
    expect(find.text('Pilih tanggal mulai dan tanggal akhir.'), findsOneWidget);
    expect(exporter.calls, isEmpty);
    await date(tester, 'Dari', 10);
    await export(tester);
    expect(exporter.calls, isEmpty);
    expect(saves, 0);
    released();
  });

  for (final outcome in ['success', 'cancel', 'error']) {
    testWidgets('Save As $outcome: cleanup, unlock, history tetap', (
      tester,
    ) async {
      save = (_) async {
        if (outcome == 'error') throw StateError('save failed');
        return outcome == 'success';
      };
      await mount(tester);
      final historyText = formatTransactionDate(
        metadata['created_at'] as String,
      );
      expect(find.text(historyText), findsOneWidget);
      await export(tester);
      expect(saves, 1);
      expect(exporter.results.single.disposals, 1);
      expect(find.text(historyText), findsOneWidget);
      expect(await BackupService().lastBackup(), metadata);
      expect(find.byType(AlertDialog), findsNothing);
      if (outcome == 'success') {
        expect(
          find.text('Export transaksi berhasil disimpan. 3 transaksi, 5 item.'),
          findsOneWidget,
        );
      } else if (outcome == 'cancel') {
        expect(find.text('Penyimpanan export dibatalkan.'), findsOneWidget);
        expect(find.textContaining('Export gagal'), findsNothing);
      } else {
        expect(find.textContaining('Export gagal:'), findsOneWidget);
      }
      available(tester);
      released();
    });
  }

  testWidgets('Engine error melepas lock dan memulihkan UI', (tester) async {
    exporter.error = const TransactionExportException('engine failed');
    await mount(tester);
    await export(tester);
    expect(find.text('Export gagal: engine failed'), findsOneWidget);
    expect(saves, 0);
    expect(exporter.results, isEmpty);
    available(tester);
    released();
  });

  testWidgets('Double export dicegah sampai save dan cleanup selesai', (
    tester,
  ) async {
    final pendingSave = Completer<bool>();
    final pendingCleanup = Completer<void>();
    save = (result) {
      (result as _Result).cleanup = pendingCleanup;
      return pendingSave.future;
    };
    await mount(tester);
    final callback = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, 'EXPORT'))
        .onPressed!;
    callback();
    callback();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(exporter.calls, hasLength(1));
    expect(saves, 1);
    expect(find.textContaining('Export gagal:'), findsNothing);
    expect(exporter.results.single.disposals, 0);
    expect(DataTransferLock.acquire(), isFalse);
    expect(
      tester
          .widget<FilledButton>(
            find.widgetWithText(FilledButton, 'MENGEKSPOR...'),
          )
          .onPressed,
      isNull,
    );
    pendingSave.complete(true);
    await tester.pump();
    expect(exporter.results.single.disposals, 1);
    callback();
    expect(exporter.calls, hasLength(1));
    expect(DataTransferLock.acquire(), isFalse);
    pendingCleanup.complete();
    await tester.pumpAndSettle();
    released();
    available(tester);
  });

  testWidgets('Lock operasi lain menolak export tanpa melepas lock pemilik', (
    tester,
  ) async {
    await mount(tester);
    expect(DataTransferLock.acquire(), isTrue);
    await export(tester);
    expect(
      find.text('Backup/pemulihan/export sedang berjalan.'),
      findsOneWidget,
    );
    expect(exporter.calls, isEmpty);
    expect(saves, 0);
    expect(DataTransferLock.acquire(), isFalse);
    DataTransferLock.release();
    await export(tester);
    expect(exporter.calls, hasLength(1));
    released();
  });
}
