// Batas integer yang tetap presisi pada seluruh target Dart.
const maxRupiah = 9007199254740991;

String formatRupiah(int value) =>
    'Rp ${value.toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+(?!\d))'), (match) => '${match[1]}.')}';

class TransactionItem {
  const TransactionItem({
    required this.productId,
    required this.kode,
    required this.nama,
    required this.price,
    required this.qty,
    this.barcode,
    this.unit,
  });

  final int productId;
  final String kode;
  final String? barcode;
  final String nama;
  final String? unit;
  final int price;
  final int qty;
  int get subtotal => price * qty;
}

int transactionTotal(List<TransactionItem> items) {
  if (items.isEmpty) throw ArgumentError('Keranjang kosong');
  var total = 0;
  final ids = <int>{};
  for (final item in items) {
    if (item.productId <= 0 ||
        !ids.add(item.productId) ||
        item.kode.isEmpty ||
        item.nama.isEmpty ||
        item.qty <= 0 ||
        item.qty > maxRupiah ||
        item.price < 0 ||
        item.price > maxRupiah ~/ item.qty) {
      throw ArgumentError('Data barang atau nilai transaksi tidak valid');
    }
    if (total > maxRupiah - item.subtotal) {
      throw ArgumentError('Nilai transaksi terlalu besar');
    }
    total += item.subtotal;
  }
  return total;
}

String transactionNumberPrefix(
  String outletCode,
  String terminalCode,
  DateTime date,
) {
  final local = date.toLocal();
  final day =
      '${local.year.toString().padLeft(4, '0')}'
      '${local.month.toString().padLeft(2, '0')}${local.day.toString().padLeft(2, '0')}';
  return '$outletCode-${terminalCode.substring(5)}-$day-';
}

class CashReceipt {
  const CashReceipt({
    required this.transactionNo,
    required this.total,
    required this.amountPaid,
    required this.changeAmount,
  });

  final String transactionNo;
  final int total;
  final int amountPaid;
  final int changeAmount;
}

class InsufficientStockException implements Exception {
  InsufficientStockException(this.products);
  final List<String> products;

  @override
  String toString() =>
      'Stok tidak cukup atau barang tidak tersedia:\n${products.join('\n')}';
}

class MissingCashierIdentityException implements Exception {
  const MissingCashierIdentityException();

  @override
  String toString() =>
      'Outlet dan terminal belum dikonfigurasi. Atur terlebih dahulu di Pengaturan.';
}
