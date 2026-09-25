import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqflite/sqflite.dart';

import '../database/database_helper.dart';
import '../models/outlet.dart';
import 'settings_service.dart';
import 'data_transfer_lock.dart';

typedef BackupExporter = Future<bool> Function(File archive, String filename);

class BackupResult {
  const BackupResult(this.metadata, {required this.historySaved});
  final Map<String, dynamic> metadata;
  final bool historySaved;
}

class BackupService {
  BackupService({
    Future<Database> Function()? database,
    Future<Directory> Function()? temporaryDirectory,
    BackupExporter? exportFile,
    DateTime Function()? now,
  }) : _database = database ?? (() => DatabaseHelper.instance.database),
       _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _exportFile = exportFile ?? _export,
       _now = now ?? DateTime.now;

  static const _historyKey = 'last_successful_backup';
  final Future<Database> Function() _database;
  final Future<Directory> Function() _temporaryDirectory;
  final BackupExporter _exportFile;
  final DateTime Function() _now;

  static String filename(DateTime time, CashierIdentity? identity) {
    final local = time.toLocal();
    String two(int value) => value.toString().padLeft(2, '0');
    final origin = identity == null
        ? 'UNSET'
        : '${identity.outletCode}_${identity.terminalCode}';
    final safeOrigin = origin.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    return 'TRISMART_Backup_${safeOrigin}_${local.year.toString().padLeft(4, '0')}'
        '${two(local.month)}${two(local.day)}_${two(local.hour)}${two(local.minute)}${two(local.second)}.trismart';
  }

  Future<Map<String, dynamic>?> lastBackup() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_historyKey);
    if (raw == null) return null;
    try {
      final value = jsonDecode(raw);
      if (value is Map<String, dynamic> &&
          value['created_at'] is String &&
          DateTime.tryParse(value['created_at'] as String) != null &&
          value['transaction_count'] is int &&
          (value['outlet_code'] == null || value['outlet_code'] is String) &&
          (value['terminal_code'] == null ||
              value['terminal_code'] is String)) {
        return value;
      }
    } on FormatException {
      return null;
    }
    return null;
  }

  /// null berarti pengguna membatalkan dialog simpan, bukan gagal/sukses.
  Future<BackupResult?> createBackup() async {
    if (!DataTransferLock.acquire()) {
      throw StateError('Backup/pemulihan sedang berjalan.');
    }
    Directory? working;
    try {
      final identity = await SettingsService().load();
      final db = await _database();
      final root = await _temporaryDirectory();
      working = await root.createTemp('trismart-backup-');
      final snapshotPath = p.join(working.path, 'database.sqlite');
      // execute ikut antrean lock sqflite: menunggu transaksi aktif selesai.
      // VACUUM INTO harus di luar BEGIN; SQLite membuat snapshot konsisten,
      // termasuk isi WAL, tanpa copy file aktif atau menutup database aplikasi.
      await db.execute('VACUUM INTO ?', [snapshotPath]);
      final createdAt = _now();
      final snapshot = await databaseFactory.openDatabase(
        snapshotPath,
        options: OpenDatabaseOptions(readOnly: true, singleInstance: false),
      );
      late final Map<String, dynamic> metadata;
      try {
        metadata = {
          'format': 'TRISMART_BACKUP',
          'backup_format_version': 1,
          'created_at': createdAt.toUtc().toIso8601String(),
          'database_version': await snapshot.getVersion(),
          'outlet_code': identity?.outletCode,
          'terminal_code': identity?.terminalCode,
          'database_file': 'database.sqlite',
          'transaction_count':
              Sqflite.firstIntValue(
                await snapshot.rawQuery('SELECT COUNT(*) FROM transactions'),
              ) ??
              0,
          'product_count':
              Sqflite.firstIntValue(
                await snapshot.rawQuery('SELECT COUNT(*) FROM products'),
              ) ??
              0,
        };
      } finally {
        await snapshot.close();
      }
      final name = filename(createdAt, identity);
      final archivePath = p.join(working.path, name);
      // Streaming file/checksum dan kompresi di isolate, bukan seluruh DB di RAM UI.
      final completeMetadata = await Isolate.run(
        () => _package(snapshotPath, archivePath, metadata),
      );
      if (!await _exportFile(File(archivePath), name)) return null;
      var historySaved = false;
      try {
        final prefs = await SharedPreferences.getInstance();
        historySaved = await prefs.setString(
          _historyKey,
          jsonEncode(completeMetadata),
        );
      } catch (_) {
        // File sudah berhasil diekspor; kegagalan catatan lokal bukan kegagalan file.
      }
      return BackupResult(completeMetadata, historySaved: historySaved);
    } finally {
      try {
        if (working != null && await working.exists()) {
          await working.delete(recursive: true);
        }
      } finally {
        DataTransferLock.release();
      }
    }
  }

  static Future<bool> _export(File archive, String filename) async {
    if (Platform.isAndroid) {
      return await const MethodChannel('trismart/backup').invokeMethod<bool>(
            'saveBackup',
            {'path': archive.path, 'filename': filename},
          ) ??
          false;
    }
    final location = await getSaveLocation(
      suggestedName: filename,
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Backup TRISMART', extensions: ['trismart']),
      ],
    );
    if (location == null) return false;
    await XFile(archive.path).saveTo(location.path);
    return true;
  }
}

Future<Map<String, dynamic>> _package(
  String snapshotPath,
  String archivePath,
  Map<String, dynamic> metadata,
) async {
  final snapshot = File(snapshotPath);
  final hash = await sha256.bind(snapshot.openRead()).first;
  final complete = {...metadata, 'database_sha256': hash.toString()};
  final metadataFile = File(p.join(p.dirname(snapshotPath), 'metadata.json'));
  await metadataFile.writeAsString(jsonEncode(complete), flush: true);
  final encoder = ZipFileEncoder();
  encoder.create(archivePath);
  try {
    await encoder.addFile(snapshot, 'database.sqlite');
    await encoder.addFile(metadataFile, 'metadata.json');
  } finally {
    await encoder.close();
  }
  return complete;
}
