import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../database/database_helper.dart';
import '../models/cash_transaction.dart';

class CashPaymentDialog extends StatefulWidget {
  const CashPaymentDialog({super.key, required this.items});
  final List<TransactionItem> items;

  @override
  State<CashPaymentDialog> createState() => _CashPaymentDialogState();
}

class _CashPaymentDialogState extends State<CashPaymentDialog> {
  final _paidController = TextEditingController();
  late final int _total = transactionTotal(widget.items);
  bool _saving = false;
  bool _finishing = false;
  CashReceipt? _receipt;
  String? _error;

  int? get _paid => int.tryParse(_paidController.text);
  bool get _canPay =>
      !_saving &&
      _receipt == null &&
      _paid != null &&
      _paid! >= _total &&
      _paid! <= maxRupiah;

  @override
  void dispose() {
    _paidController.dispose();
    super.dispose();
  }

  Future<void> _complete() async {
    if (!_canPay) return;
    final paid = _paid!;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final receipt = await DatabaseHelper.instance.completeCashTransaction(
        items: widget.items,
        amountPaid: paid,
      );
      if (mounted) setState(() => _receipt = receipt);
    } on MissingCashierIdentityException catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } on InsufficientStockException catch (error) {
      if (mounted) setState(() => _error = error.toString());
    } catch (_) {
      if (mounted) {
        setState(
          () => _error =
              'Transaksi gagal disimpan. Keranjang tetap tersedia. Silakan coba lagi.',
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _newTransaction() async {
    if (_finishing) return;
    setState(() => _finishing = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final receipt = _receipt;
    final paid = _paid;
    return PopScope<bool>(
      canPop: _finishing || (!_saving && receipt == null),
      child: AlertDialog(
        scrollable: true,
        title: Text(
          receipt == null ? 'Pembayaran Tunai' : 'Transaksi Berhasil',
        ),
        content: SizedBox(
          width: 420,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (receipt != null)
                SelectableText('Nomor: ${receipt.transactionNo}'),
              const SizedBox(height: 8),
              Text(
                'TOTAL\n${formatRupiah(_total)}',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 16),
              if (receipt == null) ...[
                TextField(
                  controller: _paidController,
                  autofocus: true,
                  enabled: !_saving,
                  keyboardType: TextInputType.number,
                  inputFormatters: [
                    FilteringTextInputFormatter.digitsOnly,
                    LengthLimitingTextInputFormatter(16),
                  ],
                  decoration: const InputDecoration(
                    labelText: 'Uang Diterima',
                    prefixText: 'Rp ',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (_) => setState(() {}),
                  onSubmitted: (_) => _complete(),
                ),
                const SizedBox(height: 12),
                Text(
                  paid != null && paid <= maxRupiah && paid >= _total
                      ? 'Kembalian: ${formatRupiah(paid - _total)}'
                      : 'Kembalian: —',
                ),
                if (paid != null && paid < _total)
                  Text('Kurang: ${formatRupiah(_total - paid)}'),
                if (paid != null && paid > maxRupiah)
                  const Text('Nominal terlalu besar.'),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                ],
                if (_saving) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
              ] else ...[
                Text('Bayar: ${formatRupiah(receipt.amountPaid)}'),
                Text('Kembalian: ${formatRupiah(receipt.changeAmount)}'),
              ],
            ],
          ),
        ),
        actions: receipt == null
            ? [
                TextButton(
                  onPressed: _saving
                      ? null
                      : () => Navigator.pop(context, false),
                  child: Text(
                    _error == null ? 'Batal' : 'Kembali ke Keranjang',
                  ),
                ),
                FilledButton(
                  onPressed: _canPay ? _complete : null,
                  child: const Text('Selesaikan Transaksi'),
                ),
              ]
            : [
                FilledButton(
                  // PopScope menahan Back; tombol eksplisit mengakhiri dialog.
                  onPressed: _finishing ? null : _newTransaction,
                  child: const Text('Transaksi Baru'),
                ),
              ],
      ),
    );
  }
}
