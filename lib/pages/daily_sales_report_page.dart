import 'package:flutter/material.dart';

import '../database/database_helper.dart';
import '../models/cash_transaction.dart';
import '../utils/transaction_date_format.dart';
import 'transaction_detail_page.dart';

class DailySalesReportPage extends StatefulWidget {
  const DailySalesReportPage({super.key});

  @override
  State<DailySalesReportPage> createState() => _DailySalesReportPageState();
}

class _DailySalesReportPageState extends State<DailySalesReportPage> {
  static const _green = Color(0xFF087F3E);
  DateTime _date = DateUtils.dateOnly(DateTime.now());
  late var _report = DatabaseHelper.instance.getDailySalesReport(_date);
  bool _showProducts = false;

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: DateTime(1900),
      lastDate: DateTime(2100, 12, 31),
    );
    if (!mounted || picked == null || picked == _date) return;
    setState(() {
      _date = picked;
      _report = DatabaseHelper.instance.getDailySalesReport(_date);
    });
  }

  Widget _summary(Map<String, dynamic> summary) {
    final values = [
      ('Jumlah transaksi', '${summary['transaction_count']}'),
      ('Total penjualan', formatRupiah(summary['total_sales'] as int)),
      ('Total qty barang terjual', '${summary['total_qty']}'),
      // Nilai AVG tetap presisi di query; tampilan mengikuti Rupiah bulat aplikasi.
      (
        'Rata-rata nilai transaksi',
        formatRupiah((summary['average_transaction'] as num).round()),
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth >= 700
            ? 4
            : constraints.maxWidth < 300 ||
                  MediaQuery.textScalerOf(context).scale(14) > 21
            ? 1
            : 2;
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final value in values)
              SizedBox(
                width: (constraints.maxWidth - (columns - 1) * 8) / columns,
                child: Card(
                  margin: EdgeInsets.zero,
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(value.$1),
                        const SizedBox(height: 6),
                        Text(
                          value.$2,
                          style: const TextStyle(
                            color: _green,
                            fontSize: 20,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _row(Map<String, dynamic> row) => Card(
    color: Colors.white,
    child: InkWell(
      onTap: _showProducts
          ? null
          : () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    TransactionDetailPage(transactionId: row['id'] as int),
              ),
            ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              row[_showProducts ? 'nama' : 'transaction_no'] as String,
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(
              _showProducts
                  ? 'PLU/kode: ${row['kode']}'
                  : 'Jam: ${formatTransactionDate(row['transaction_date'] as String).split(' ').last}',
            ),
            Text('Total qty: ${row['total_qty']}'),
            Text(
              '${_showProducts ? 'Omzet' : 'Total'}: ${formatRupiah(row[_showProducts ? 'revenue' : 'total'] as int)}',
              style: const TextStyle(
                color: _green,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    ),
  );

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: const Color(0xFFF2F7F3),
    appBar: AppBar(
      title: const Text('Laporan Penjualan'),
      foregroundColor: _green,
    ),
    body: SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 960),
          child: FutureBuilder(
            future: _report,
            builder: (context, snapshot) {
              final ready = snapshot.connectionState == ConnectionState.done;
              final report = ready && !snapshot.hasError ? snapshot.data : null;
              final rows = _showProducts
                  ? report?.products
                  : report?.transactions;
              return ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: 1 + (rows?.length ?? 0),
                itemBuilder: (context, index) {
                  if (index > 0) return _row(rows![index - 1]);
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Text(
                        'TRISMART • Penjualan harian',
                        style: TextStyle(
                          color: _green,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 12),
                      OutlinedButton.icon(
                        onPressed: _pickDate,
                        icon: const Icon(Icons.calendar_month),
                        label: Text(
                          'Tanggal: ${_date.day.toString().padLeft(2, '0')}/${_date.month.toString().padLeft(2, '0')}/${_date.year}',
                        ),
                      ),
                      const SizedBox(height: 12),
                      if (!ready)
                        const Center(child: CircularProgressIndicator())
                      else if (snapshot.hasError) ...[
                        const Text('Gagal memuat laporan penjualan.'),
                        TextButton(
                          onPressed: () => setState(() {
                            _report = DatabaseHelper.instance
                                .getDailySalesReport(_date);
                          }),
                          child: const Text('Coba lagi'),
                        ),
                      ] else if (report != null) ...[
                        _summary(report.summary),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 8,
                          runSpacing: 8,
                          children: [
                            ChoiceChip(
                              label: const Text('TRANSAKSI'),
                              selected: !_showProducts,
                              onSelected: (_) =>
                                  setState(() => _showProducts = false),
                            ),
                            ChoiceChip(
                              label: const Text('BARANG TERJUAL'),
                              selected: _showProducts,
                              onSelected: (_) =>
                                  setState(() => _showProducts = true),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (report.summary['transaction_count'] == 0)
                          const Padding(
                            padding: EdgeInsets.symmetric(vertical: 32),
                            child: Column(
                              children: [
                                Icon(
                                  Icons.receipt_long_outlined,
                                  color: _green,
                                  size: 48,
                                ),
                                SizedBox(height: 12),
                                Text(
                                  'Belum ada transaksi selesai pada tanggal ini.',
                                  textAlign: TextAlign.center,
                                ),
                                SizedBox(height: 8),
                                Text(
                                  'Pilih tanggal lain untuk melihat laporan.',
                                  textAlign: TextAlign.center,
                                ),
                              ],
                            ),
                          ),
                      ],
                    ],
                  );
                },
              );
            },
          ),
        ),
      ),
    ),
  );
}
