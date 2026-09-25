import 'dart:collection';

import 'package:flutter/material.dart';

import '../database/database_helper.dart';
import '../models/cash_transaction.dart';
import 'barcode_scanner_page.dart';
import 'cash_payment_dialog.dart';

class TransactionPage extends StatefulWidget {
  const TransactionPage({super.key});

  @override
  State<TransactionPage> createState() => _TransactionPageState();
}

class _CartItem {
  _CartItem(Map<String, dynamic> product)
    : id = product['id'] as int,
      kode = product['kode'] as String,
      nama = product['nama'] as String,
      barcode = product['barcode'] as String?,
      unit = product['unit'] as String?,
      harga = _integerPrice(product['harga_jual']);

  static int _integerPrice(dynamic value) {
    final price = value as num? ?? 0;
    if (!price.isFinite || price < 0 || price > maxRupiah) {
      throw ArgumentError('Harga barang tidak valid');
    }
    // Master masih REAL; konversi sekali ke Rupiah terdekat saat masuk keranjang.
    return price.round();
  }

  final int id;
  final String kode;
  final String nama;
  final String? barcode;
  final String? unit;
  final int harga;
  int qty = 1;

  int get subtotal => harga * qty;

  TransactionItem snapshot() => TransactionItem(
    productId: id,
    kode: kode,
    barcode: barcode,
    nama: nama,
    unit: unit,
    price: harga,
    qty: qty,
  );
}

class _TransactionPageState extends State<TransactionPage> {
  final _input = TextEditingController();
  final _inputFocus = FocusNode();
  final _cart = <int, _CartItem>{};
  final _pendingScans = Queue<String>();
  bool _lookingUp = false;
  bool _confirming = false;
  bool _cameraOpen = false;

  Future<void> _scanCamera() async {
    if (_cameraOpen || _confirming || _lookingUp) return;
    setState(() => _cameraOpen = true);
    _inputFocus.unfocus();
    try {
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => BarcodeScannerPage(
            onScan: _lookupAndAdd,
            cartSummary: () {
              final qty = _cart.values.fold<int>(
                0,
                (sum, item) => sum + item.qty,
              );
              final total = _cart.values.fold<int>(
                0,
                (sum, item) => sum + item.subtotal,
              );
              return 'Qty total: $qty • Total: ${_rupiah(total)}';
            },
          ),
        ),
      );
    } catch (_) {
      if (mounted) _message('Kamera tidak tersedia. Gunakan input manual.');
    } finally {
      if (mounted) {
        setState(() => _cameraOpen = false);
        _inputFocus.requestFocus();
      }
    }
  }

  @override
  void dispose() {
    _pendingScans.clear();
    _input.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  void _submit(String value) {
    if (_confirming) return;
    final code = value.trim();
    _input.clear();
    _inputFocus.requestFocus();
    if (code.isEmpty) return;
    // Simpan setiap submit agar scan cepat tidak hilang selama query berjalan.
    _pendingScans.add(code);
    if (!_lookingUp) _processScans();
  }

  Future<void> _processScans() async {
    setState(() => _lookingUp = true);
    try {
      while (mounted && _pendingScans.isNotEmpty) {
        final code = _pendingScans.removeFirst();
        final result = await _lookupAndAdd(code);
        if (!mounted) return;
        if (!result.added) _message(result.message);
        // Jangan menghapus input baru yang sedang diketik/di-scan.
        if (mounted) _inputFocus.requestFocus();
      }
    } finally {
      if (mounted) setState(() => _lookingUp = false);
    }
  }

  // Satu jalur lookup dan perubahan keranjang untuk input manual maupun kamera.
  Future<({bool added, String message})> _lookupAndAdd(String code) async {
    try {
      final db = DatabaseHelper.instance;
      final product =
          await db.getProductByBarcode(code) ?? await db.getProductByKode(code);
      if (!mounted) return (added: false, message: 'Transaksi sudah ditutup');
      if (product == null) {
        return (added: false, message: 'Barang tidak ditemukan');
      }
      if (product['aktif'] != 1) {
        return (added: false, message: 'Barang tidak aktif');
      }
      final item = _CartItem(product);
      setState(() {
        final existing = _cart[item.id];
        if (existing == null) {
          _cart[item.id] = item;
        } else {
          existing.qty++;
        }
      });
      return (added: true, message: '${item.nama}\nDitambahkan ke keranjang');
    } catch (_) {
      return (
        added: false,
        message: 'Gagal mencari barang. Silakan scan ulang.',
      );
    }
  }

  void _message(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  void _changeQty(_CartItem item, int delta) {
    setState(() {
      item.qty += delta;
      if (item.qty == 0) _cart.remove(item.id);
    });
    _inputFocus.requestFocus();
  }

  Future<void> _clearCart() async {
    setState(() => _confirming = true);
    try {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Kosongkan Keranjang?'),
          content: const Text('Semua barang di keranjang akan dihapus.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Batal'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Kosongkan'),
            ),
          ],
        ),
      );
      if (mounted && confirmed == true) setState(_cart.clear);
    } finally {
      if (mounted) {
        setState(() => _confirming = false);
        _inputFocus.requestFocus();
      }
    }
  }

  String _rupiah(int value) => formatRupiah(value);

  Future<void> _pay() async {
    if (_cart.isEmpty || _lookingUp || _confirming || _cameraOpen) return;
    final items = List<TransactionItem>.unmodifiable(
      _cart.values.map((item) => item.snapshot()),
    );
    try {
      transactionTotal(items);
    } on ArgumentError catch (error) {
      _message(error.message.toString());
      return;
    }
    setState(() => _confirming = true);
    _inputFocus.unfocus();
    try {
      final completed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => CashPaymentDialog(items: items),
      );
      if (mounted && completed == true) {
        setState(_cart.clear);
        _input.clear();
      }
    } finally {
      if (mounted) {
        setState(() => _confirming = false);
        _inputFocus.requestFocus();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final items = _cart.values.toList(growable: false);
    final qty = items.fold<int>(0, (sum, item) => sum + item.qty);
    final total = items.fold<int>(0, (sum, item) => sum + item.subtotal);
    return Scaffold(
      appBar: AppBar(title: const Text('Transaksi')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _input,
                    focusNode: _inputFocus,
                    autofocus: true,
                    enabled: !_confirming,
                    autocorrect: false,
                    enableSuggestions: false,
                    textInputAction: TextInputAction.done,
                    onEditingComplete: () {},
                    onSubmitted: _submit,
                    decoration: InputDecoration(
                      labelText: 'Scan / ketik Barcode atau PLU',
                      border: const OutlineInputBorder(),
                      suffixIcon: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            tooltip: 'Scan dengan kamera',
                            onPressed: _confirming || _cameraOpen || _lookingUp
                                ? null
                                : _scanCamera,
                            icon: const Icon(Icons.camera_alt_outlined),
                          ),
                          IconButton(
                            tooltip: 'Tambah barang',
                            onPressed: _confirming
                                ? null
                                : () => _submit(_input.text),
                            icon: const Icon(Icons.add_shopping_cart),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  height: 2,
                  child: _lookingUp ? const LinearProgressIndicator() : null,
                ),
                Expanded(
                  child: items.isEmpty
                      ? const Center(child: Text('Keranjang masih kosong'))
                      : ListView.builder(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          itemCount: items.length,
                          itemBuilder: (context, index) {
                            final item = items[index];
                            return Card(
                              key: ValueKey(item.id),
                              child: Padding(
                                padding: const EdgeInsets.all(12),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      item.nama,
                                      style: Theme.of(
                                        context,
                                      ).textTheme.titleMedium,
                                    ),
                                    Text('PLU: ${item.kode}'),
                                    Text(
                                      'Harga satuan: ${_rupiah(item.harga)}',
                                    ),
                                    Wrap(
                                      spacing: 16,
                                      crossAxisAlignment:
                                          WrapCrossAlignment.center,
                                      children: [
                                        Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            IconButton(
                                              tooltip:
                                                  'Kurangi qty ${item.nama}',
                                              onPressed: () =>
                                                  _changeQty(item, -1),
                                              icon: const Icon(
                                                Icons.remove_circle_outline,
                                              ),
                                            ),
                                            Text('Qty: ${item.qty}'),
                                            IconButton(
                                              tooltip:
                                                  'Tambah qty ${item.nama}',
                                              onPressed: () =>
                                                  _changeQty(item, 1),
                                              icon: const Icon(
                                                Icons.add_circle_outline,
                                              ),
                                            ),
                                          ],
                                        ),
                                        Text(
                                          'Subtotal: ${_rupiah(item.subtotal)}',
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        ),
                ),
                const Divider(height: 1),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text('${items.length} jenis barang • Qty total: $qty'),
                      Text(
                        'TOTAL: ${_rupiah(total)}',
                        style: Theme.of(context).textTheme.headlineSmall,
                      ),
                      const SizedBox(height: 8),
                      FilledButton(
                        onPressed:
                            items.isEmpty ||
                                _lookingUp ||
                                _confirming ||
                                _cameraOpen
                            ? null
                            : _pay,
                        child: const Text('Bayar'),
                      ),
                      OutlinedButton.icon(
                        onPressed: items.isEmpty || _lookingUp || _confirming
                            ? null
                            : _clearCart,
                        icon: const Icon(Icons.remove_shopping_cart_outlined),
                        label: const Text('Kosongkan Keranjang'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
