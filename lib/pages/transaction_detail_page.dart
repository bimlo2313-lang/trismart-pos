import 'package:flutter/material.dart';

import '../database/database_helper.dart';
import '../models/cash_transaction.dart';
import '../models/outlet.dart';
import '../utils/transaction_date_format.dart';
import 'pos_reentry_page.dart';

class TransactionDetailPage extends StatefulWidget {
  const TransactionDetailPage({super.key, required this.transactionId});
  final int transactionId;

  @override
  State<TransactionDetailPage> createState() => _TransactionDetailPageState();
}

class _TransactionDetailPageState extends State<TransactionDetailPage> {
  Map<String, dynamic>? _transaction;
  List<Map<String, dynamic>> _items = [];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final db = DatabaseHelper.instance;
      final transaction = await db.getTransactionById(widget.transactionId);
      final items = transaction == null
          ? <Map<String, dynamic>>[]
          : await db.getTransactionItems(widget.transactionId);
      if (!mounted) return;
      setState(() {
        _transaction = transaction;
        _items = items;
      });
    } catch (_) {
      if (mounted) setState(() => _error = 'Gagal memuat detail transaksi.');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Widget _content() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            TextButton(onPressed: _load, child: const Text('Coba lagi')),
          ],
        ),
      );
    }
    final transaction = _transaction;
    if (transaction == null) {
      return const Center(child: Text('Transaksi tidak ditemukan.'));
    }
    final outletCode = transaction['outlet_code'] as String?;
    final outlet = outletByCode(outletCode);
    final outletLabel = outletCode == null
        ? 'Tidak tersedia'
        : outlet == null
        ? outletCode
        : '${outlet.name} ($outletCode)';
    return ListView.builder(
      padding: const EdgeInsets.all(16),
      itemCount: _items.length + 1,
      itemBuilder: (context, index) {
        if (index == 0) {
          return Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SelectableText(
                  transaction['transaction_no'] as String,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  formatTransactionDate(
                    transaction['transaction_date'] as String,
                  ),
                ),
                Text('Status: ${transaction['status']}'),
                Text('Outlet: $outletLabel'),
                Text(
                  'Terminal: ${transaction['terminal_code'] ?? 'Tidak tersedia'}',
                ),
                Text('Pembayaran: ${transaction['payment_method']}'),
                const SizedBox(height: 8),
                Text(
                  'Total: ${formatRupiah(transaction['total'] as int)}',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Text(
                  'Uang diterima: ${formatRupiah(transaction['amount_paid'] as int)}',
                ),
                Text(
                  'Kembalian: ${formatRupiah(transaction['change_amount'] as int)}',
                ),
                const Divider(),
                FilledButton.icon(
                  onPressed: _items.isEmpty
                      ? null
                      : () => Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (_) => PosReentryPage(
                              transactionNo:
                                  transaction['transaction_no'] as String,
                              items: _items,
                            ),
                          ),
                        ),
                  icon: const Icon(Icons.barcode_reader),
                  label: const Text('Input Ulang ke POS'),
                ),
                const SizedBox(height: 12),
                Text(
                  'Detail Barang (${_items.length})',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
              ],
            ),
          );
        }
        final item = _items[index - 1];
        final barcode = item['barcode'] as String?;
        return Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item['nama'] as String,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text('PLU/kode: ${item['kode']}'),
                const SizedBox(height: 8),
                const Text('Barcode'),
                SelectableText(
                  barcode == null || barcode.trim().isEmpty
                      ? 'Barcode tidak tersedia'
                      : barcode,
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.bold),
                ),
                const SizedBox(height: 8),
                Text('Harga: ${formatRupiah(item['price'] as int)}'),
                Text('Qty: ${item['qty']} ${item['unit'] ?? ''}'),
                Text('Subtotal: ${formatRupiah(item['subtotal'] as int)}'),
              ],
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Detail Transaksi')),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: _content(),
        ),
      ),
    ),
  );
}
