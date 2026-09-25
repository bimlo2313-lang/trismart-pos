import 'package:flutter_test/flutter_test.dart';
import 'package:kasir_app/models/cash_transaction.dart';

TransactionItem item({int id = 1, int price = 12500, int qty = 1}) =>
    TransactionItem(
      productId: id,
      kode: 'P$id',
      nama: 'Barang $id',
      price: price,
      qty: qty,
    );

void main() {
  test('Total memakai snapshot harga dan integer Rupiah', () {
    expect(
      transactionTotal([item(qty: 3), item(id: 2, price: 750, qty: 2)]),
      39000,
    );
    expect(formatRupiah(39000), 'Rp 39.000');
    expect(formatRupiah(0), 'Rp 0');
  });

  test('Tolak keranjang kosong, qty invalid dan produk duplikat', () {
    expect(() => transactionTotal([]), throwsArgumentError);
    expect(() => transactionTotal([item(qty: 0)]), throwsArgumentError);
    expect(() => transactionTotal([item(price: -1)]), throwsArgumentError);
    expect(() => transactionTotal([item(), item()]), throwsArgumentError);
  });

  test('Tolak overflow subtotal dan total sebelum penyimpanan', () {
    expect(
      () => transactionTotal([item(price: maxRupiah, qty: 2)]),
      throwsArgumentError,
    );
    expect(
      () => transactionTotal([item(price: maxRupiah), item(id: 2)]),
      throwsArgumentError,
    );
  });

  test('Prefix nomor memakai outlet, nomor terminal dan tanggal lokal', () {
    expect(
      transactionNumberPrefix('KWD', 'TERM-01', DateTime(2026, 9, 25)),
      'KWD-01-20260925-',
    );
  });
}
