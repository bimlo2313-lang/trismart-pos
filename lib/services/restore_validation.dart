import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:archive/archive_io.dart' as zip;
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

const maxRestoreArchiveBytes = 256 * 1024 * 1024;
const maxRestoreDatabaseBytes = 512 * 1024 * 1024;
const _maxMetadataBytes = 64 * 1024;

class RestoreException implements Exception {
  const RestoreException(this.message, {this.critical = false});
  final String message;
  final bool critical;
  @override
  String toString() => message;
}

class ValidatedBackup {
  ValidatedBackup(this.directory, Map<String, dynamic> metadata)
    : metadata = Map.unmodifiable(metadata);
  final Directory directory;
  final Map<String, dynamic> metadata;
  void Function()? onDispose;
  String get databasePath => p.join(directory.path, 'database.sqlite');
  Future<void> dispose() async {
    try {
      if (await directory.exists()) await directory.delete(recursive: true);
    } finally {
      onDispose?.call();
      onDispose = null;
    }
  }
}

Future<ValidatedBackup> validateBackupPackage(
  File package,
  Directory area,
) async {
  try {
    final packagePath = package.path;
    final outputPath = area.path;
    final metadata = await Isolate.run(() => _extract(packagePath, outputPath));
    await validateDatabaseFile(p.join(area.path, 'database.sqlite'), metadata);
    return ValidatedBackup(area, metadata);
  } on RestoreException {
    rethrow;
  } catch (_) {
    throw const RestoreException('File backup rusak atau tidak dapat dibaca.');
  }
}

Future<Map<String, dynamic>> _extract(String package, String area) async {
  final file = File(package);
  final length = await file.length();
  if (length < 22 || length > maxRestoreArchiveBytes) {
    throw const RestoreException(
      'Ukuran file backup tidak valid (maksimal 256 MB).',
    );
  }
  // Batasi directory sebelum parser ZIP mengalokasikan header. Format 1 hanya 2 file.
  final handle = await file.open();
  late final Uint8List tail;
  try {
    await handle.setPosition(max(0, length - 65557));
    tail = await handle.read(min(length, 65557));
  } finally {
    await handle.close();
  }
  var end = -1;
  final view = ByteData.sublistView(tail);
  for (var i = tail.length - 22; i >= 0; i--) {
    if (view.getUint32(i, Endian.little) == 0x06054b50 &&
        i + 22 + view.getUint16(i + 20, Endian.little) == tail.length) {
      end = i;
      break;
    }
  }
  if (end < 0 ||
      (end >= 20 && view.getUint32(end - 20, Endian.little) == 0x07064b50) ||
      view.getUint32(end + 16, Endian.little) +
              view.getUint32(end + 12, Endian.little) !=
          length - tail.length + end ||
      view.getUint16(end + 4, Endian.little) != 0 ||
      view.getUint16(end + 6, Endian.little) != 0 ||
      view.getUint16(end + 8, Endian.little) != 2 ||
      view.getUint16(end + 10, Endian.little) != 2 ||
      view.getUint32(end + 12, Endian.little) > _maxMetadataBytes) {
    throw const RestoreException(
      'Isi paket backup tidak sesuai format TRISMART.',
    );
  }
  final input = zip.InputFileStream(package);
  try {
    final directory = zip.ZipDirectory()..read(input);
    final names = <String>{};
    if (directory.fileHeaders.length != 2) {
      throw const FormatException('Entries');
    }
    for (final entry in directory.fileHeaders) {
      final name = entry.filename;
      final data = entry.file;
      final limit = name == 'metadata.json'
          ? _maxMetadataBytes
          : maxRestoreDatabaseBytes;
      if (!{'metadata.json', 'database.sqlite'}.contains(name) ||
          !names.add(name) ||
          data == null ||
          data.filename != name ||
          entry.uncompressedSize <= 0 ||
          entry.uncompressedSize > limit ||
          data.uncompressedSize != entry.uncompressedSize ||
          entry.compressedSize > maxRestoreArchiveBytes ||
          entry.generalPurposeBitFlag & 1 != 0 ||
          data.flags & 1 != 0 ||
          !{0, 8}.contains(entry.compressionMethod) ||
          data.compressionMethod !=
              (entry.compressionMethod == 0
                  ? zip.CompressionType.none
                  : zip.CompressionType.deflate) ||
          ((entry.externalFileAttributes >> 16) & 0xf000) == 0xa000) {
        throw const RestoreException(
          'Isi paket backup tidak aman, duplikat, atau terlalu besar.',
        );
      }
      // Nama allowlist saja: tidak pernah memakai path entry bebas untuk menulis.
      final output = _BoundedFileSink(
        File(p.join(area, name)),
        entry.uncompressedSize,
      );
      try {
        final raw = data.getStream(decompress: false);
        final Sink<List<int>> sink = entry.compressionMethod == 8
            ? ZLibDecoder(raw: true).startChunkedConversion(output)
            : output;
        while (!raw.isEOS) {
          sink.add(raw.readBytes(min(32768, raw.length)).toUint8List());
        }
        sink.close();
        if (output.written != entry.uncompressedSize) {
          throw const FormatException('Size');
        }
      } finally {
        output.close();
      }
    }
  } finally {
    await input.close();
  }
  final raw = jsonDecode(
    await File(p.join(area, 'metadata.json')).readAsString(),
  );
  if (raw is! Map<String, dynamic> ||
      raw['format'] != 'TRISMART_BACKUP' ||
      raw['backup_format_version'] is! int ||
      raw['backup_format_version'] != 1 ||
      raw['database_version'] is! int ||
      raw['database_version'] != 5 ||
      raw['database_file'] != 'database.sqlite' ||
      raw['created_at'] is! String ||
      DateTime.tryParse(raw['created_at'] as String) == null ||
      (raw['outlet_code'] != null && raw['outlet_code'] is! String) ||
      (raw['terminal_code'] != null && raw['terminal_code'] is! String)) {
    throw const RestoreException('Metadata atau versi backup tidak didukung.');
  }
  for (final count in ['product_count', 'transaction_count']) {
    if (raw.containsKey(count) &&
        (raw[count] is! int || (raw[count] as int) < 0)) {
      throw const RestoreException('Jumlah data pada metadata tidak valid.');
    }
  }
  final hash =
      (await sha256
              .bind(File(p.join(area, 'database.sqlite')).openRead())
              .first)
          .toString();
  if (hash != raw['database_sha256']) {
    throw const RestoreException(
      'Checksum backup tidak cocok. File rusak atau telah berubah.',
    );
  }
  return raw;
}

class _BoundedFileSink implements Sink<List<int>> {
  _BoundedFileSink(File file, this.limit)
    : _file = file.openSync(mode: FileMode.write);
  final RandomAccessFile _file;
  final int limit;
  int written = 0;
  bool _closed = false;
  @override
  void add(List<int> data) {
    if (_closed || written + data.length > limit) {
      throw const FormatException('Decompression limit');
    }
    _file.writeFromSync(data);
    written += data.length;
  }

  @override
  void close() {
    if (!_closed) {
      _closed = true;
      _file.closeSync();
    }
  }
}

Future<void> validateDatabaseFile(
  String path,
  Map<String, dynamic> metadata,
) async {
  final file = File(path);
  if (!await file.exists() || await file.length() < 100) {
    throw const RestoreException('Database backup tidak valid.');
  }
  final header = await file.open();
  try {
    if (ascii.decode(await header.read(16), allowInvalid: true) !=
        'SQLite format 3\u0000') {
      throw const RestoreException('File backup bukan database SQLite.');
    }
  } finally {
    await header.close();
  }
  final db = await openDatabase(path, readOnly: true, singleInstance: false);
  try {
    await validateRestoreDatabase(db, metadata);
  } finally {
    await db.close();
  }
}

Future<void> validateRestoreDatabase(
  Database db,
  Map<String, dynamic> metadata,
) async {
  final integrity = await db.rawQuery('PRAGMA integrity_check');
  if (integrity.length != 1 || integrity.single.values.single != 'ok') {
    throw const RestoreException('Pemeriksaan integritas database gagal.');
  }
  if (await db.getVersion() != 5) {
    throw const RestoreException('Versi database backup harus 5.');
  }
  const columns = {
    'products': [
      'id',
      'kode',
      'barcode',
      'nama',
      'unit',
      'harga_jual',
      'stok',
      'lokasi',
      'aktif',
    ],
    'transactions': [
      'id',
      'transaction_no',
      'transaction_date',
      'total',
      'payment_method',
      'amount_paid',
      'change_amount',
      'status',
      'outlet_code',
      'terminal_code',
    ],
    'transaction_items': [
      'id',
      'transaction_id',
      'product_id',
      'kode',
      'barcode',
      'nama',
      'unit',
      'price',
      'qty',
      'subtotal',
    ],
  };
  // Format v1 berasal dari schema aplikasi; tolak trigger/view/virtual table asing.
  final schema = await db.rawQuery(
    "SELECT type, name, sql FROM sqlite_master WHERE name NOT LIKE 'sqlite_%'",
  );
  if (schema.any(
    (r) =>
        r['type'] == 'trigger' ||
        r['type'] == 'view' ||
        (r['sql'] as String? ?? '').toUpperCase().contains(
          'CREATE VIRTUAL TABLE',
        ),
  )) {
    throw const RestoreException('Schema database backup tidak didukung.');
  }
  for (final table in columns.entries) {
    if (!schema.any((r) => r['type'] == 'table' && r['name'] == table.key)) {
      throw const RestoreException('Tabel wajib database tidak lengkap.');
    }
    final info = await db.rawQuery('PRAGMA table_info(${table.key})');
    final names = info.map((r) => r['name']).toSet();
    if (!names.containsAll(table.value) ||
        !info.any(
          (r) => r['name'] == 'id' && r['pk'] == 1 && r['type'] == 'INTEGER',
        )) {
      throw const RestoreException('Kolom wajib database tidak lengkap.');
    }
    await db.query(table.key, columns: table.value, limit: 1);
  }
  for (final pair in [
    ('products', 'kode'),
    ('transactions', 'transaction_no'),
  ]) {
    var unique = false;
    for (final index in await db.rawQuery('PRAGMA index_list(${pair.$1})')) {
      if (index['unique'] != 1 || index['partial'] != 0) continue;
      final name = (index['name'] as String).replaceAll("'", "''");
      final fields = await db.rawQuery("PRAGMA index_info('$name')");
      if (fields.length == 1 && fields.single['name'] == pair.$2) unique = true;
    }
    if (!unique) {
      throw const RestoreException('Constraint database backup tidak lengkap.');
    }
  }
  if ((await db.rawQuery('PRAGMA foreign_key_check')).isNotEmpty) {
    throw const RestoreException('Relasi data backup tidak valid.');
  }
  for (final pair in [
    ('products', 'product_count'),
    ('transactions', 'transaction_count'),
  ]) {
    final actual = Sqflite.firstIntValue(
      await db.rawQuery('SELECT COUNT(*) FROM ${pair.$1}'),
    )!;
    if (metadata.containsKey(pair.$2) && metadata[pair.$2] != actual) {
      throw const RestoreException(
        'Jumlah data backup tidak cocok dengan metadata.',
      );
    }
    metadata.putIfAbsent(pair.$2, () => actual);
  }
}
