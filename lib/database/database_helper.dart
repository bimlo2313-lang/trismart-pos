import 'dart:io';

import 'package:path/path.dart';
import 'package:sqflite/sqflite.dart';
import '../models/cash_transaction.dart';
import '../services/settings_service.dart';

class DatabaseRestoreAccess {
  DatabaseRestoreAccess._(this._helper, this.database);
  final DatabaseHelper _helper;
  Database database;

  Future<void> close() async {
    await database.close();
    DatabaseHelper._database = null;
  }

  Future<Database> reopen() async {
    database = await _helper._initDatabase(restoring: true);
    DatabaseHelper._database = database;
    return database;
  }

  void block() => _helper._restoreBlocked = true;
}

class DatabaseHelper {
  static final DatabaseHelper instance = DatabaseHelper._internal();

  static Database? _database;
  Future<Database>? _opening;
  bool _restoring = false;
  bool _restoreBlocked = false;

  DatabaseHelper._internal();

  Future<Database> get database async {
    if (_restoring || _restoreBlocked) {
      throw StateError(
        'Database sedang dipulihkan atau memerlukan bantuan IT.',
      );
    }
    if (_database != null) {
      return _database!;
    }

    try {
      _opening ??= _initDatabase();
      _database = await _opening!;
      return _database!;
    } finally {
      _opening = null;
    }
  }

  Future<Database> _initDatabase({bool restoring = false}) async {
    final databasePath = await getDatabasesPath();
    final path = join(databasePath, 'kasir.db');
    if (!restoring && await File('$path.restore-pending').exists()) {
      _restoreBlocked = true;
      throw StateError(
        'Pemulihan belum selesai. Hentikan transaksi dan hubungi IT.',
      );
    }
    if (restoring &&
        (!await File(path).exists() || await File(path).length() == 0)) {
      throw StateError('Database pemulihan tidak tersedia.');
    }

    return await openDatabase(
      path,
      version: 5,
      onConfigure: (db) => db.execute('PRAGMA foreign_keys = ON'),
      onCreate: _createDatabase,
      onUpgrade: _upgradeDatabase,
    );
  }

  /// Hanya lifecycle restore; semua pemanggil baru ditolak selama replacement.
  Future<T> withRestoreLock<T>(
    Future<T> Function(DatabaseRestoreAccess access) action,
  ) async {
    final db = await database;
    if (_restoring) throw StateError('Pemulihan sedang berjalan.');
    _restoring = true;
    try {
      return await action(DatabaseRestoreAccess._(this, db));
    } finally {
      _restoring = false;
    }
  }

  Future<void> _createDatabase(Database db, int version) async {
    await db.execute('''
      CREATE TABLE products (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        kode TEXT NOT NULL UNIQUE,
        barcode TEXT,
        nama TEXT NOT NULL,
        unit TEXT,
        harga_jual REAL DEFAULT 0,
        stok REAL DEFAULT 0,
        lokasi TEXT,
        aktif INTEGER DEFAULT 1
      )
    ''');
    await _createProductIndexes(db);
    await _createTransactionTables(db);
    await _createHistoryIndex(db);
    await _addTransactionIdentity(db);
  }

  Future<void> _upgradeDatabase(
    Database db,
    int oldVersion,
    int newVersion,
  ) async {
    if (oldVersion < 2) {
      await _createProductIndexes(db);
    }
    if (oldVersion < 3) {
      await _createTransactionTables(db);
    }
    if (oldVersion < 4) {
      await _createHistoryIndex(db);
    }
    if (oldVersion < 5) {
      await _addTransactionIdentity(db);
    }
  }

  Future<void> _addTransactionIdentity(Database db) async {
    await db.execute(
      'ALTER TABLE transactions ADD COLUMN outlet_code TEXT NULL',
    );
    await db.execute(
      'ALTER TABLE transactions ADD COLUMN terminal_code TEXT NULL',
    );
  }

  Future<void> _createHistoryIndex(Database db) => db.execute(
    'CREATE INDEX IF NOT EXISTS idx_transactions_date_id '
    'ON transactions(transaction_date DESC, id DESC)',
  );

  String _transactionSearchPattern(String keyword) {
    final escaped = keyword
        .trim()
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    return '%$escaped%';
  }

  ({String where, List<Object> args}) _transactionFilters({
    String keyword = '',
    DateTime? fromDate,
    DateTime? toDate,
    String? paymentMethod,
    String? status,
  }) {
    final clauses = <String>[];
    final args = <Object>[];
    if (keyword.trim().isNotEmpty) {
      clauses.add("transaction_no LIKE ? ESCAPE '\\'");
      args.add(_transactionSearchPattern(keyword));
    }
    // Tanggal pilihan memakai hari lokal; transaction_date tersimpan sebagai ISO UTC.
    // Enam digit pecahan detik mencakup nilai ISO dengan 3 maupun 6 digit.
    String boundary(DateTime date, int extraDays) {
      final utc = DateTime(date.year, date.month, date.day + extraDays).toUtc();
      return '${utc.toIso8601String().substring(0, 19)}.000000Z';
    }

    if (fromDate != null) {
      clauses.add('transaction_date >= ?');
      args.add(boundary(fromDate, 0));
    }
    if (toDate != null) {
      clauses.add('transaction_date < ?');
      args.add(boundary(toDate, 1));
    }
    if (paymentMethod != null) {
      clauses.add('payment_method = ?');
      args.add(paymentMethod);
    }
    if (status != null) {
      clauses.add('status = ?');
      args.add(status);
    }
    return (
      where: clauses.isEmpty ? '' : 'WHERE ${clauses.join(' AND ')}',
      args: args,
    );
  }

  Future<int> countTransactions({
    String keyword = '',
    DateTime? fromDate,
    DateTime? toDate,
    String? paymentMethod,
    String? status,
  }) async {
    final db = await database;
    final filter = _transactionFilters(
      keyword: keyword,
      fromDate: fromDate,
      toDate: toDate,
      paymentMethod: paymentMethod,
      status: status,
    );
    final result = await db.rawQuery(
      'SELECT COUNT(*) FROM transactions ${filter.where}',
      filter.args,
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  Future<List<Map<String, dynamic>>> getTransactions({
    int limit = 30,
    int offset = 0,
    String keyword = '',
    DateTime? fromDate,
    DateTime? toDate,
    String? paymentMethod,
    String? status,
    bool oldestFirst = false,
  }) async {
    _validatePagination(limit, offset);
    final db = await database;
    final filter = _transactionFilters(
      keyword: keyword,
      fromDate: fromDate,
      toDate: toDate,
      paymentMethod: paymentMethod,
      status: status,
    );
    final order = oldestFirst ? 'ASC' : 'DESC';
    // Batasi header lebih dahulu; agregasi detail hanya untuk halaman ini.
    return db.rawQuery(
      '''
      SELECT t.*,
        (SELECT COUNT(*) FROM transaction_items i
          WHERE i.transaction_id = t.id) AS item_count,
        (SELECT COALESCE(SUM(i.qty), 0) FROM transaction_items i
          WHERE i.transaction_id = t.id) AS total_qty
      FROM (
        SELECT * FROM transactions
        ${filter.where}
        ORDER BY transaction_date $order, id $order
        LIMIT ? OFFSET ?
      ) t
      ORDER BY t.transaction_date $order, t.id $order
    ''',
      [...filter.args, limit, offset],
    );
  }

  Future<Map<String, dynamic>?> getTransactionById(int id) async {
    final db = await database;
    final rows = await db.query(
      'transactions',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    return rows.isEmpty ? null : rows.first;
  }

  /// Semua SELECT memakai snapshot database yang sama, tanpa menulis data.
  Future<
    ({
      Map<String, dynamic> summary,
      List<Map<String, dynamic>> transactions,
      List<Map<String, dynamic>> products,
    })
  >
  getDailySalesReport(DateTime date) async {
    final db = await database;
    final filter = _transactionFilters(
      fromDate: date,
      toDate: date,
      status: 'COMPLETED',
    );
    return db.transaction((txn) async {
      final summary = await txn.rawQuery('''
        SELECT COUNT(*) AS transaction_count,
          COALESCE(SUM(t.total), 0) AS total_sales,
          COALESCE(AVG(t.total), 0) AS average_transaction,
          COALESCE(SUM((SELECT SUM(i.qty) FROM transaction_items i
            WHERE i.transaction_id = t.id)), 0) AS total_qty
        FROM transactions t ${filter.where}
      ''', filter.args);
      final transactions = await txn.rawQuery('''
        SELECT t.id, t.transaction_no, t.transaction_date, t.total,
          (SELECT COALESCE(SUM(i.qty), 0) FROM transaction_items i
            WHERE i.transaction_id = t.id) AS total_qty
        FROM transactions t ${filter.where}
        ORDER BY t.transaction_date DESC, t.id DESC
      ''', filter.args);
      final products = await txn.rawQuery('''
        SELECT i.kode, i.nama, SUM(i.qty) AS total_qty,
          SUM(i.subtotal) AS revenue
        FROM transaction_items i
        JOIN transactions t ON t.id = i.transaction_id
        ${filter.where}
        GROUP BY i.kode, i.nama
        ORDER BY total_qty DESC, i.nama COLLATE NOCASE ASC, i.kode ASC
      ''', filter.args);
      return (
        summary: summary.single,
        transactions: transactions,
        products: products,
      );
    });
  }

  Future<List<Map<String, dynamic>>> getTransactionItems(
    int transactionId,
  ) async {
    final db = await database;
    // Snapshot saja, tanpa join ke products.
    return db.query(
      'transaction_items',
      where: 'transaction_id = ?',
      whereArgs: [transactionId],
      orderBy: 'id ASC',
    );
  }

  Future<void> _createTransactionTables(Database db) async {
    await db.execute('''
      CREATE TABLE transactions (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        transaction_no TEXT NOT NULL UNIQUE,
        transaction_date TEXT NOT NULL,
        total INTEGER NOT NULL,
        payment_method TEXT NOT NULL,
        amount_paid INTEGER NOT NULL,
        change_amount INTEGER NOT NULL,
        status TEXT NOT NULL DEFAULT 'COMPLETED'
      )
    ''');
    await db.execute('''
      CREATE TABLE transaction_items (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        transaction_id INTEGER NOT NULL,
        product_id INTEGER NOT NULL,
        kode TEXT NOT NULL,
        barcode TEXT,
        nama TEXT NOT NULL,
        unit TEXT,
        price INTEGER NOT NULL,
        qty INTEGER NOT NULL,
        subtotal INTEGER NOT NULL,
        FOREIGN KEY (transaction_id) REFERENCES transactions(id)
      )
    ''');
    await db.execute(
      'CREATE INDEX idx_transaction_items_transaction_id '
      'ON transaction_items(transaction_id)',
    );
  }

  Future<CashReceipt> completeCashTransaction({
    required List<TransactionItem> items,
    required int amountPaid,
    DateTime Function()? now,
  }) async {
    final snapshot = List<TransactionItem>.unmodifiable(items);
    final total = transactionTotal(snapshot);
    if (amountPaid < total || amountPaid > maxRupiah) {
      throw ArgumentError('Uang diterima tidak valid');
    }
    final identity = await SettingsService().load();
    if (identity == null || identity.outlet?.active != true) {
      throw const MissingCashierIdentityException();
    }
    final db = await database;
    return db.transaction((txn) async {
      // Satu waktu untuk tanggal lokal nomor dan timestamp UTC yang disimpan.
      final createdAt = (now ?? DateTime.now)();
      final prefix = transactionNumberPrefix(
        identity.outletCode,
        identity.terminalCode,
        createdAt,
      );
      // GLOB tanpa wildcard akhir hanya menerima tepat enam digit ASCII.
      // MAX memakai kolom UNIQUE terindeks; nomor legacy/malformed diabaikan.
      final rows = await txn.rawQuery(
        'SELECT MAX(transaction_no) AS last_no FROM transactions WHERE transaction_no GLOB ?',
        ['$prefix[0-9][0-9][0-9][0-9][0-9][0-9]'],
      );
      final last = rows.single['last_no'] as String?;
      final sequence = last == null
          ? 1
          : int.parse(last.substring(prefix.length)) + 1;
      if (sequence > 999999) {
        throw StateError(
          'Urutan transaksi harian sudah mencapai batas enam digit.',
        );
      }
      final transactionNo = '$prefix${sequence.toString().padLeft(6, '0')}';
      // INSERT biasa: nomor yang sama tidak boleh menyimpan/mengurangi stok lagi.
      final transactionId = await txn.insert('transactions', {
        'transaction_no': transactionNo,
        'transaction_date': createdAt.toUtc().toIso8601String(),
        'total': total,
        'payment_method': 'CASH',
        'amount_paid': amountPaid,
        'change_amount': amountPaid - total,
        'status': 'COMPLETED',
        'outlet_code': identity.outletCode,
        'terminal_code': identity.terminalCode,
      });
      final shortages = <String>[];
      final batch = txn.batch();
      for (final item in snapshot) {
        final updated = await txn.rawUpdate(
          '''
          UPDATE products SET stok = stok - ?
          WHERE id = ? AND kode = ? AND aktif = 1 AND stok >= ?
        ''',
          [item.qty, item.productId, item.kode, item.qty],
        );
        if (updated != 1) shortages.add('${item.nama} (${item.kode})');
        batch.insert('transaction_items', {
          'transaction_id': transactionId,
          'product_id': item.productId,
          'kode': item.kode,
          'barcode': item.barcode,
          'nama': item.nama,
          'unit': item.unit,
          'price': item.price,
          'qty': item.qty,
          'subtotal': item.subtotal,
        });
      }
      if (shortages.isNotEmpty) throw InsufficientStockException(shortages);
      await batch.commit(noResult: true, continueOnError: false);
      return CashReceipt(
        transactionNo: transactionNo,
        total: total,
        amountPaid: amountPaid,
        changeAmount: amountPaid - total,
      );
    });
  }

  Future<void> _createProductIndexes(Database db) async {
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_products_barcode ON products(barcode)',
    );
    await db.execute(
      'CREATE INDEX IF NOT EXISTS idx_products_nama_id ON products(nama, id)',
    );
  }

  // ==============================
  // TAMBAH BARANG
  // ==============================

  Future<int> insertProduct(Map<String, dynamic> product) async {
    final db = await database;

    // Konflik kode memperbarui row yang sama tanpa mengganti id.
    return await db.rawInsert(
      '''
      INSERT INTO products
        (kode, barcode, nama, unit, harga_jual, stok, lokasi, aktif)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?)
      ON CONFLICT(kode) DO UPDATE SET
        barcode = excluded.barcode,
        nama = excluded.nama,
        unit = excluded.unit,
        harga_jual = excluded.harga_jual,
        stok = excluded.stok,
        lokasi = excluded.lokasi,
        aktif = excluded.aktif
    ''',
      [
        product['kode'],
        product['barcode'],
        product['nama'],
        product['unit'],
        product.containsKey('harga_jual') ? product['harga_jual'] : 0,
        product.containsKey('stok') ? product['stok'] : 0,
        product['lokasi'],
        product.containsKey('aktif') ? product['aktif'] : 1,
      ],
    );
  }

  // ==============================
  // AMBIL SATU HALAMAN BARANG
  // ==============================

  Future<List<Map<String, dynamic>>> getProducts({
    int limit = 50,
    int offset = 0,
  }) async {
    _validatePagination(limit, offset);
    final db = await database;

    return await db.query(
      'products',
      orderBy: 'nama ASC, id ASC',
      limit: limit,
      offset: offset,
    );
  }

  // ==============================
  // CARI BARANG
  // berdasarkan nama, kode, barcode
  // ==============================

  Future<List<Map<String, dynamic>>> searchProducts(
    String keyword, {
    int limit = 50,
    int offset = 0,
    bool transactionNameSearch = false,
  }) async {
    _validatePagination(limit, offset);
    if (transactionNameSearch && keyword.trim().length < 2) return [];
    final db = await database;

    return await db.query(
      'products',
      where: transactionNameSearch
          ? "aktif = 1 AND nama LIKE ? ESCAPE '\\'"
          : _searchWhere,
      whereArgs: transactionNameSearch
          ? [_searchArgs(keyword).first]
          : _searchArgs(keyword),
      orderBy: 'nama ASC, id ASC',
      limit: transactionNameSearch ? limit.clamp(1, 20) : limit,
      offset: offset,
    );
  }

  static const _searchWhere =
      "nama LIKE ? ESCAPE '\\' OR kode LIKE ? ESCAPE '\\' "
      "OR barcode LIKE ? ESCAPE '\\'";

  List<String> _searchArgs(String keyword) {
    final escaped = keyword
        .trim()
        .replaceAll('\\', '\\\\')
        .replaceAll('%', '\\%')
        .replaceAll('_', '\\_');
    return List.filled(3, '%$escaped%');
  }

  Future<int> countProducts({String keyword = ''}) async {
    final db = await database;
    final hasKeyword = keyword.trim().isNotEmpty;
    final result = await db.rawQuery(
      'SELECT COUNT(*) FROM products${hasKeyword ? ' WHERE $_searchWhere' : ''}',
      hasKeyword ? _searchArgs(keyword) : null,
    );
    return Sqflite.firstIntValue(result) ?? 0;
  }

  void _validatePagination(int limit, int offset) {
    if (limit <= 0 || offset < 0) {
      throw ArgumentError('limit harus positif dan offset tidak boleh negatif');
    }
  }

  // ==============================
  // CARI BERDASARKAN BARCODE
  // ==============================

  Future<Map<String, dynamic>?> getProductByBarcode(String barcode) async {
    final raw = barcode.trim();
    if (raw.isEmpty) return null;
    final db = await database;

    // Prioritaskan nilai persis; data tersimpan tidak selalu sudah dinormalisasi.
    // Coba hanya selisih SATU nol, tanpa normalisasi berulang/strip semua nol.
    final candidates = [
      raw,
      if (raw.startsWith('0') && raw.length > 1) raw.substring(1),
      '0$raw',
    ];
    for (final candidate in candidates) {
      final result = await db.query(
        'products',
        where: 'barcode = ?',
        whereArgs: [candidate],
        orderBy: 'id ASC',
        limit: 1,
      );
      if (result.isNotEmpty) return result.first;
    }
    return null;
  }

  // ==============================
  // CARI BERDASARKAN KODE / PLU
  // ==============================

  Future<Map<String, dynamic>?> getProductByKode(String kode) async {
    final db = await database;

    final result = await db.query(
      'products',
      where: 'kode = ?',
      whereArgs: [kode],
      limit: 1,
    );

    if (result.isEmpty) {
      return null;
    }

    return result.first;
  }

  // ==============================
  // UPDATE BARANG
  // ==============================

  Future<int> updateProduct(int id, Map<String, dynamic> product) async {
    final db = await database;

    return await db.update(
      'products',
      product,
      where: 'id = ?',
      whereArgs: [id],
    );
  }

  // ==============================
  // HAPUS BARANG
  // ==============================

  Future<int> deleteProduct(int id) async {
    final db = await database;

    return await db.delete('products', where: 'id = ?', whereArgs: [id]);
  }

  Future<void> importProductsBatch(List<Map<String, dynamic>> products) async {
    final db = await database;

    await db.transaction((txn) async {
      final batch = txn.batch();

      for (final product in products) {
        // Konflik kode memperbarui row yang sama tanpa mengganti id.
        batch.rawInsert(
          '''
          INSERT INTO products
            (kode, barcode, nama, unit, harga_jual, stok, lokasi, aktif)
          VALUES (?, ?, ?, ?, ?, ?, ?, ?)
          ON CONFLICT(kode) DO UPDATE SET
            barcode = excluded.barcode,
            nama = excluded.nama,
            unit = excluded.unit,
            harga_jual = excluded.harga_jual,
            stok = excluded.stok,
            lokasi = excluded.lokasi,
            aktif = excluded.aktif
        ''',
          [
            product['kode'],
            product['barcode'],
            product['nama'],
            product['unit'],
            product['harga_jual'],
            product['stok'],
            product['lokasi'],
            product['aktif'],
          ],
        );
      }

      await batch.commit(noResult: true, continueOnError: false);
    });
  }
}
