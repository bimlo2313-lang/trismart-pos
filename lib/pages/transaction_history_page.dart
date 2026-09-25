import 'dart:async';

import 'package:flutter/material.dart';

import '../database/database_helper.dart';
import '../models/cash_transaction.dart';
import '../utils/transaction_date_format.dart';
import 'transaction_detail_page.dart';

class TransactionHistoryPage extends StatefulWidget {
  const TransactionHistoryPage({super.key});

  @override
  State<TransactionHistoryPage> createState() => _TransactionHistoryPageState();
}

class _TransactionHistoryPageState extends State<TransactionHistoryPage> {
  static const _pageSize = 30;
  final _db = DatabaseHelper.instance;
  final _search = TextEditingController();
  Timer? _debounce;
  List<Map<String, dynamic>> _transactions = [];
  int _page = 0;
  int _total = 0;
  int _request = 0;
  bool _loading = true;
  String? _error;
  DateTime? _fromDate;
  DateTime? _toDate;
  String? _paymentMethod;
  String? _status;
  bool _oldestFirst = false;
  String? _quickFilter;

  String _dateLabel(DateTime date) =>
      '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year}';

  void _filtersChanged() {
    _debounce?.cancel();
    setState(() => _page = 0);
    _load();
  }

  Future<void> _quickDate(String label) async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    DateTime from = today;
    DateTime to = today;
    if (label == 'Kemarin') {
      from = to = DateTime(now.year, now.month, now.day - 1);
    } else if (label == '7 Hari') {
      from = DateTime(now.year, now.month, now.day - 6);
    } else if (label == 'Pilih Tanggal') {
      final picked = await showDatePicker(
        context: context,
        initialDate: _fromDate ?? today,
        firstDate: DateTime(1900),
        lastDate: DateTime(2100, 12, 31),
      );
      if (!mounted || picked == null) return;
      from = to = picked;
    }
    setState(() {
      _fromDate = from;
      _toDate = to;
      _quickFilter = label;
    });
    _filtersChanged();
  }

  Future<void> _moreFilters() async {
    var from = _fromDate;
    var to = _toDate;
    var payment = _paymentMethod ?? '';
    var status = _status ?? '';
    var oldest = _oldestFirst;
    final applied = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) {
          final invalidRange = from != null && to != null && from!.isAfter(to!);
          Future<void> pickDate(bool start) async {
            final picked = await showDatePicker(
              context: context,
              initialDate: (start ? from : to) ?? DateTime.now(),
              firstDate: DateTime(1900),
              lastDate: DateTime(2100, 12, 31),
            );
            if (!context.mounted || picked == null) return;
            update(() {
              if (start) {
                from = picked;
              } else {
                to = picked;
              }
            });
          }

          return AlertDialog(
            title: const Text('Filter Lainnya'),
            scrollable: true,
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Dari tanggal'),
                    subtitle: Text(
                      from == null ? 'Semua tanggal' : _dateLabel(from!),
                    ),
                    onTap: () => pickDate(true),
                    trailing: from == null
                        ? const Icon(Icons.calendar_today)
                        : IconButton(
                            onPressed: () => update(() => from = null),
                            icon: const Icon(Icons.clear),
                          ),
                  ),
                  ListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Sampai tanggal'),
                    subtitle: Text(
                      to == null ? 'Semua tanggal' : _dateLabel(to!),
                    ),
                    onTap: () => pickDate(false),
                    trailing: to == null
                        ? const Icon(Icons.calendar_today)
                        : IconButton(
                            onPressed: () => update(() => to = null),
                            icon: const Icon(Icons.clear),
                          ),
                  ),
                  if (invalidRange)
                    Text(
                      'Sampai tanggal harus sama atau setelah Dari tanggal.',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  DropdownButtonFormField<String>(
                    key: ValueKey('payment-$payment'),
                    initialValue: payment,
                    decoration: const InputDecoration(
                      labelText: 'Metode pembayaran',
                    ),
                    items: const [
                      DropdownMenuItem(value: '', child: Text('Semua')),
                      DropdownMenuItem(value: 'CASH', child: Text('Tunai')),
                    ],
                    onChanged: (value) => update(() => payment = value ?? ''),
                  ),
                  DropdownButtonFormField<String>(
                    key: ValueKey('status-$status'),
                    initialValue: status,
                    decoration: const InputDecoration(labelText: 'Status'),
                    items: const [
                      DropdownMenuItem(value: '', child: Text('Semua')),
                      DropdownMenuItem(
                        value: 'COMPLETED',
                        child: Text('COMPLETED'),
                      ),
                    ],
                    onChanged: (value) => update(() => status = value ?? ''),
                  ),
                  DropdownButtonFormField<bool>(
                    key: ValueKey('order-$oldest'),
                    initialValue: oldest,
                    decoration: const InputDecoration(labelText: 'Urutan'),
                    items: const [
                      DropdownMenuItem(value: false, child: Text('Terbaru')),
                      DropdownMenuItem(value: true, child: Text('Terlama')),
                    ],
                    onChanged: (value) => update(() => oldest = value ?? false),
                  ),
                  TextButton(
                    onPressed: () {
                      from = null;
                      to = null;
                      payment = '';
                      status = '';
                      oldest = false;
                      Navigator.pop(dialogContext, true);
                    },
                    child: const Text('Reset Filter'),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, false),
                child: const Text('Batal'),
              ),
              FilledButton(
                onPressed: invalidRange
                    ? null
                    : () => Navigator.pop(dialogContext, true),
                child: const Text('Terapkan'),
              ),
            ],
          );
        },
      ),
    );
    if (!mounted || applied != true) return;
    setState(() {
      _fromDate = from;
      _toDate = to;
      _paymentMethod = payment.isEmpty ? null : payment;
      _status = status.isEmpty ? null : status;
      _oldestFirst = oldest;
      _quickFilter = null;
    });
    _filtersChanged();
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _search.dispose();
    super.dispose();
  }

  Future<void> _load({int page = 0}) async {
    final request = ++_request;
    final keyword = _search.text.trim();
    final from = _fromDate;
    final to = _toDate;
    final payment = _paymentMethod;
    final status = _status;
    final oldest = _oldestFirst;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final total = await _db.countTransactions(
        keyword: keyword,
        fromDate: from,
        toDate: to,
        paymentMethod: payment,
        status: status,
      );
      final lastPage = total == 0 ? 0 : (total - 1) ~/ _pageSize;
      final target = page.clamp(0, lastPage);
      final rows = await _db.getTransactions(
        limit: _pageSize,
        offset: target * _pageSize,
        keyword: keyword,
        fromDate: from,
        toDate: to,
        paymentMethod: payment,
        status: status,
        oldestFirst: oldest,
      );
      if (!mounted || request != _request) return;
      setState(() {
        _transactions = rows;
        _total = total;
        _page = target;
      });
    } catch (_) {
      if (!mounted || request != _request) return;
      setState(() => _error = 'Gagal memuat riwayat transaksi.');
    } finally {
      if (mounted && request == _request) setState(() => _loading = false);
    }
  }

  void _searchChanged(String _) {
    _debounce?.cancel();
    ++_request; // Abaikan hasil query untuk kata kunci sebelumnya.
    setState(() {
      _loading = true;
      _page = 0;
    });
    _debounce = Timer(const Duration(milliseconds: 300), () => _load());
  }

  Widget _list() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_error!),
            TextButton(
              onPressed: () => _load(page: _page),
              child: const Text('Coba lagi'),
            ),
          ],
        ),
      );
    }
    if (_transactions.isEmpty) {
      return Center(
        child: Text(
          'Tidak ada transaksi yang cocok dengan pencarian dan filter.',
        ),
      );
    }
    return ListView.builder(
      key: ValueKey((
        _page,
        _search.text.trim(),
        _fromDate,
        _toDate,
        _paymentMethod,
        _status,
        _oldestFirst,
      )),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      itemCount: _transactions.length,
      itemBuilder: (context, index) {
        final row = _transactions[index];
        return Card(
          child: InkWell(
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) =>
                    TransactionDetailPage(transactionId: row['id'] as int),
              ),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    row['transaction_no'] as String,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatTransactionDate(row['transaction_date'] as String),
                  ),
                  Text(
                    '${row['item_count']} jenis barang • Qty total: ${row['total_qty']}',
                  ),
                  Text(
                    formatRupiah(row['total'] as int),
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  Text('Pembayaran: ${row['payment_method']}'),
                  Text('Status: ${row['status']}'),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final enabled = !_loading && _error == null;
    return Scaffold(
      appBar: AppBar(title: const Text('Riwayat Transaksi')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 960),
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextField(
                    controller: _search,
                    onChanged: _searchChanged,
                    decoration: const InputDecoration(
                      labelText: 'Cari nomor transaksi',
                      prefixIcon: Icon(Icons.search),
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      for (final label in [
                        'Hari Ini',
                        'Kemarin',
                        '7 Hari',
                        'Pilih Tanggal',
                      ])
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: ChoiceChip(
                            label: Text(label),
                            selected: _quickFilter == label,
                            onSelected: (_) => _quickDate(label),
                          ),
                        ),
                      OutlinedButton.icon(
                        onPressed: _moreFilters,
                        icon: const Icon(Icons.filter_list),
                        label: const Text('Filter Lainnya'),
                      ),
                    ],
                  ),
                ),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Row(
                    children: [
                      if (_fromDate != null || _toDate != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: InputChip(
                            label: Text(
                              '${_fromDate == null ? 'Awal' : _dateLabel(_fromDate!)} – ${_toDate == null ? 'Seterusnya' : _dateLabel(_toDate!)}',
                            ),
                            onDeleted: () {
                              _fromDate = null;
                              _toDate = null;
                              _quickFilter = null;
                              _filtersChanged();
                            },
                          ),
                        ),
                      if (_paymentMethod != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: InputChip(
                            label: const Text('Tunai'),
                            onDeleted: () {
                              _paymentMethod = null;
                              _filtersChanged();
                            },
                          ),
                        ),
                      if (_status != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: InputChip(
                            label: Text(_status!),
                            onDeleted: () {
                              _status = null;
                              _filtersChanged();
                            },
                          ),
                        ),
                      Chip(label: Text(_oldestFirst ? 'Terlama' : 'Terbaru')),
                    ],
                  ),
                ),
                Expanded(child: _list()),
                Wrap(
                  alignment: WrapAlignment.spaceEvenly,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    TextButton(
                      onPressed: enabled && _page > 0
                          ? () => _load(page: _page - 1)
                          : null,
                      child: const Text('Sebelumnya'),
                    ),
                    Text('Halaman ${_page + 1}'),
                    TextButton(
                      onPressed: enabled && (_page + 1) * _pageSize < _total
                          ? () => _load(page: _page + 1)
                          : null,
                      child: const Text('Berikutnya'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
