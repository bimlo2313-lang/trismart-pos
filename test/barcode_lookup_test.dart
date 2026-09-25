import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:kasir_app/database/database_helper.dart';
import 'package:sqflite/sqflite.dart';

// Isolasi database perangkat; test menjalankan helper produksi dan memeriksa
// parameter query exact yang dikirim melalui API sqflite.
class _LookupDatabase implements Database {
  final products = <Map<String, Object?>>[];
  final candidates = <String>[];

  @override
  Future<List<Map<String, Object?>>> query(
    String table, {
    bool? distinct,
    List<String>? columns,
    String? where,
    List<Object?>? whereArgs,
    String? groupBy,
    String? having,
    String? orderBy,
    int? limit,
    int? offset,
  }) async {
    expect(table, 'products');
    expect(limit, 1);
    expect(where, anyOf('barcode = ?', 'kode = ?'));
    final column = where == 'barcode = ?' ? 'barcode' : 'kode';
    if (column == 'barcode') candidates.add(whereArgs!.single as String);
    return products
        .where((row) => row[column] == whereArgs!.single)
        .take(1)
        .toList();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final db = _LookupDatabase();
  final helper = DatabaseHelper.instance;
  setUpAll(() {
    databaseFactory = databaseFactorySqflitePlugin;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(const MethodChannel('com.tekartik.sqflite'), (
          call,
        ) async {
          if (call.method == 'getDatabasesPath') return '/lookup-test-only';
          if (call.method == 'openDatabase') return {'id': 1};
          if (call.method == 'execute') return {'transactionId': 1};
          if (call.method == 'query') {
            final args = call.arguments as Map;
            final sql = args['sql'] as String;
            if (sql == 'PRAGMA user_version') {
              return [
                {'user_version': 5},
              ];
            }
            expect(sql, startsWith('SELECT * FROM products WHERE '));
            expect(sql, endsWith('LIMIT 1'));
            return db.query(
              'products',
              where: sql.contains('barcode = ?') ? 'barcode = ?' : 'kode = ?',
              whereArgs: List<Object?>.from(args['arguments'] as List),
              limit: 1,
            );
          }
          throw StateError('Unexpected SQLite operation: ${call.method}');
        });
  });
  setUp(() {
    db.products.clear();
    db.candidates.clear();
  });

  void product(String barcode, {int id = 1}) => db.products.add({
    'id': id,
    'barcode': barcode,
    'kode': 'PLU$id',
    'nama': 'Barang',
    'aktif': 1,
  });

  for (final pair in [
    ('123456789', '123456789'),
    ('123456789', '0123456789'),
    ('0123456789', '123456789'),
    ('0123456789', '0123456789'),
  ]) {
    test('DB ${pair.$1}, scan ${pair.$2} ditemukan', () async {
      product(pair.$1);
      expect((await helper.getProductByBarcode(pair.$2))?['id'], 1);
    });
  }
  test('Barcode tidak ada mengembalikan null', () async {
    product('123456789');
    expect(await helper.getProductByBarcode('999'), isNull);
  });
  test('Tidak menghapus atau menambahkan dua nol sekaligus', () async {
    product('00123456789');
    expect(await helper.getProductByBarcode('123456789'), isNull);
    db.products.clear();
    product('123456789');
    expect(await helper.getProductByBarcode('00123456789'), isNull);
  });
  test('Nilai persis diprioritaskan jika kedua varian ada', () async {
    product('123456789');
    product('0123456789', id: 2);
    expect((await helper.getProductByBarcode('0123456789'))?['id'], 2);
    expect(db.candidates, ['0123456789']);
  });
  test('Trim input dan lookup PLU fallback tetap tersedia', () async {
    product('123456789');
    expect((await helper.getProductByBarcode(' 0123456789\r\n'))?['id'], 1);
    expect(await helper.getProductByBarcode('PLU1'), isNull);
    expect((await helper.getProductByKode('PLU1'))?['id'], 1);
  });
  test('Input kosong tidak mencari barcode kosong', () async {
    product('');
    expect(await helper.getProductByBarcode('  '), isNull);
    expect(db.candidates, isEmpty);
  });
}
