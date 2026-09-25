import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../database/database_helper.dart';
import 'data_transfer_lock.dart';
import 'restore_validation.dart';

typedef RestorePicker = Future<bool> Function(File destination);

class RestoreService {
  RestoreService({
    Future<Directory> Function()? temporaryDirectory,
    RestorePicker? picker,
  }) : _temporaryDirectory = temporaryDirectory ?? getTemporaryDirectory,
       _picker = picker ?? _pick;
  final Future<Directory> Function() _temporaryDirectory;
  final RestorePicker _picker;
  ValidatedBackup? _prepared;
  bool _restoring = false;

  Future<ValidatedBackup?> prepare() async {
    if (!DataTransferLock.acquire()) {
      throw const RestoreException('Backup atau pemulihan sedang berjalan.');
    }
    Directory? area;
    try {
      area = await (await _temporaryDirectory()).createTemp(
        'trismart-restore-',
      );
      final archive = File(p.join(area.path, 'selected.trismart'));
      if (!await _picker(archive)) {
        await area.delete(recursive: true);
        DataTransferLock.release();
        return null;
      }
      final validated = await validateBackupPackage(archive, area);
      _prepared = validated;
      validated.onDispose = () {
        _prepared = null;
        DataTransferLock.release();
      };
      return validated;
    } catch (error) {
      try {
        if (area != null && await area.exists()) {
          await area.delete(recursive: true);
        }
      } finally {
        DataTransferLock.release();
      }
      if (error is RestoreException) rethrow;
      throw const RestoreException(
        'Backup tidak dapat dibaca atau terlalu besar (maksimal 256 MB).',
      );
    }
  }

  Future<void> restore(ValidatedBackup backup) async {
    if (_restoring || !identical(backup, _prepared)) {
      throw const RestoreException('Sesi pemulihan tidak valid.');
    }
    _restoring = true;
    try {
      // Ulangi checksum/schema sebelum replacement untuk mendeteksi perubahan selama preview.
      final checked = await validateBackupPackage(
        File(p.join(backup.directory.path, 'selected.trismart')),
        backup.directory,
      );
      if (checked.metadata['database_sha256'] !=
          backup.metadata['database_sha256']) {
        throw const RestoreException(
          'Backup berubah setelah preview. Pilih ulang file.',
        );
      }
      await DatabaseHelper.instance.withRestoreLock((access) async {
        final activePath = access.database.path;
        final recovery = await Directory(
          p.dirname(activePath),
        ).createTemp('trismart-recovery-');
        final safetyPath = p.join(recovery.path, 'safety.sqlite');
        final stagedPath = p.join(recovery.path, 'replacement.sqlite');
        final marker = File('$activePath.restore-pending');
        var started = false;
        var retainRecovery = false;
        final oldMetadata = <String, dynamic>{};
        try {
          await access.database.execute('VACUUM INTO ?', [safetyPath]);
          await validateDatabaseFile(safetyPath, oldMetadata);
          await File(backup.databasePath).copy(stagedPath);
          started = true;
          await marker.writeAsString(recovery.path, flush: true);
          await access.close();
          await _removeSidecars(activePath);
          // Original tetap tersedia bagi IT sampai hasil akhir diketahui.
          await File(
            activePath,
          ).rename(p.join(recovery.path, 'original.sqlite'));
          await File(stagedPath).rename(activePath);
          await afterReplacement();
          final restored = await access.reopen();
          await validateRestoreDatabase(restored, {...backup.metadata});
          await marker.delete();
        } catch (error) {
          if (!started) {
            throw const RestoreException(
              'Pemulihan dibatalkan karena safety backup gagal. Database sebelumnya tidak diganti.',
            );
          }
          try {
            await access.close();
            await _removeSidecars(activePath);
            await beforeRollback();
            // Copy safety ke staging dahulu: safety tidak pernah dipindah/ditimpa.
            final rollbackPath = p.join(recovery.path, 'rollback.sqlite');
            await File(safetyPath).copy(rollbackPath);
            if (await File(activePath).exists()) {
              await File(activePath).delete();
            }
            await File(rollbackPath).rename(activePath);
            final previous = await access.reopen();
            await validateRestoreDatabase(previous, oldMetadata);
            if (await marker.exists()) await marker.delete();
          } catch (_) {
            retainRecovery = true;
            access.block();
            throw const RestoreException(
              'Pemulihan dan pengembalian data gagal. Hentikan transaksi dan hubungi IT. Safety backup tetap disimpan di perangkat.',
              critical: true,
            );
          }
          throw const RestoreException(
            'Pemulihan gagal. Data sebelumnya telah dikembalikan.',
          );
        } finally {
          if (!retainRecovery && await recovery.exists()) {
            await recovery.delete(recursive: true);
          }
        }
      });
    } finally {
      _restoring = false;
      await backup.dispose();
    }
  }

  @visibleForTesting
  Future<void> afterReplacement() async {}
  @visibleForTesting
  Future<void> beforeRollback() async {}

  static Future<void> _removeSidecars(String databasePath) async {
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final file = File('$databasePath$suffix');
      if (await file.exists()) await file.delete();
    }
  }

  static Future<bool> _pick(File destination) async {
    if (Platform.isAndroid) {
      return await const MethodChannel('trismart/backup').invokeMethod<bool>(
            'openBackup',
            {'path': destination.path, 'maxBytes': maxRestoreArchiveBytes},
          ) ??
          false;
    }
    final selected = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Backup TRISMART', extensions: ['trismart']),
      ],
    );
    if (selected == null) return false;
    if (!selected.name.toLowerCase().endsWith('.trismart')) {
      throw const RestoreException('Pilih file .trismart.');
    }
    final output = destination.openWrite();
    var size = 0;
    try {
      await for (final bytes in selected.openRead()) {
        size += bytes.length;
        if (size > maxRestoreArchiveBytes) {
          throw const RestoreException('File backup melebihi batas 256 MB.');
        }
        output.add(bytes);
      }
      await output.flush();
    } finally {
      await output.close();
    }
    return true;
  }
}
