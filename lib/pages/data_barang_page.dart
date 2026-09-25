import 'dart:async';

import 'package:flutter/material.dart';
import '../database/database_helper.dart';
import '../services/import_service.dart';

class DataBarangPage extends StatefulWidget {
  const DataBarangPage({super.key});

  @override
  State<DataBarangPage> createState() => _DataBarangPageState();
}

class _DataBarangPageState extends State<DataBarangPage> {
  static const _pageSize = 50;
  final DatabaseHelper _databaseHelper = DatabaseHelper.instance;
  final ImportService _importService = ImportService();
  final TextEditingController _searchController = TextEditingController();
  Timer? _searchDebounce;
  List<Map<String, dynamic>> _products = [];
  int _page = 0;
  int _total = 0;
  int _loadRequest = 0;
  String _keyword = '';
  String? _loadError;
  bool _isLoading = true;
  bool _isImporting = false;

  @override
  void initState() {
    super.initState();
    _loadProducts();
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _loadProducts({int page = 0}) async {
    final request = ++_loadRequest;
    final keyword = _keyword;
    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final total = await _databaseHelper.countProducts(keyword: keyword);
      final lastPage = total == 0 ? 0 : (total - 1) ~/ _pageSize;
      final targetPage = page.clamp(0, lastPage);
      final products = keyword.isEmpty
          ? await _databaseHelper.getProducts(
              limit: _pageSize,
              offset: targetPage * _pageSize,
            )
          : await _databaseHelper.searchProducts(
              keyword,
              limit: _pageSize,
              offset: targetPage * _pageSize,
            );
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _products = products;
        _total = total;
        _page = targetPage;
      });
    } catch (e) {
      if (!mounted || request != _loadRequest) return;
      setState(() {
        _products = [];
        _total = 0;
        _loadError = 'Gagal memuat barang: $e';
      });
    } finally {
      if (mounted && request == _loadRequest) {
        setState(() => _isLoading = false);
      }
    }
  }

  void _searchChanged(String value) {
    _searchDebounce?.cancel();
    // Abaikan hasil query lama sejak input berubah, termasuk selama debounce.
    ++_loadRequest;
    setState(() {
      _keyword = value.trim();
      _page = 0;
      _isLoading = true;
      _loadError = null;
    });
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _loadProducts();
    });
  }

  Future<void> _importCsv() async {
    setState(() => _isImporting = true);
    try {
      final result = await _importService.importCsv();
      if (!mounted) return;
      if (result.error == 'IMPORT_DIBATALKAN') return;
      if (result.error != null) {
        _showImportError(result.error!);
        return;
      }
      _searchDebounce?.cancel();
      _searchController.clear();
      _keyword = '';
      await _loadProducts();
      if (!mounted) return;
      await showDialog<void>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Import Selesai'),
          content: Text(
            'Total baris: ${result.totalRows}\n'
            'Berhasil diproses: ${result.imported}\n'
            'Dilewati: ${result.skipped}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    } catch (e) {
      if (mounted) _showImportError(e.toString());
    } finally {
      if (mounted) setState(() => _isImporting = false);
    }
  }

  void _showImportError(String error) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Import gagal:\n$error'),
        duration: const Duration(seconds: 5),
      ),
    );
  }

  Widget _buildProducts() {
    if (_isLoading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_loadError != null) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(_loadError!, textAlign: TextAlign.center),
            TextButton(
              onPressed: _isImporting ? null : () => _loadProducts(page: _page),
              child: const Text('Coba lagi'),
            ),
          ],
        ),
      );
    }
    if (_products.isEmpty) {
      return Center(
        child: Text(
          _keyword.isEmpty
              ? 'Belum ada data barang.'
              : 'Tidak ada barang yang cocok.',
        ),
      );
    }
    return ListView.builder(
      key: ValueKey((_keyword, _page)),
      itemCount: _products.length,
      itemBuilder: (context, index) {
        final product = _products[index];
        final stok = product['stok'] as num?;
        final stokText = stok == null
            ? '-'
            : stok.isFinite && stok == stok.truncateToDouble()
            ? stok.toInt().toString()
            : stok.toString();
        final unit = (product['unit'] as String? ?? '').trim();
        return ListTile(
          leading: const Icon(Icons.inventory_2),
          title: Text(product['nama'] ?? ''),
          subtitle: Text(
            'Kode/PLU: ${product['kode']}'
            '\nBarcode: ${product['barcode'] ?? '-'}'
            '\nStok: $stokText${unit.isEmpty ? '' : ' $unit'}'
            '\nHarga: Rp ${product['harga_jual']}',
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final canNavigate = !_isLoading && !_isImporting && _loadError == null;
    return Scaffold(
      appBar: AppBar(
        title: const Text(
          'Data Barang',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        actions: [
          if (_isImporting)
            const Padding(
              padding: EdgeInsets.all(16),
              child: SizedBox(
                width: 22,
                height: 22,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            )
          else
            IconButton(
              onPressed: _isLoading ? null : _importCsv,
              tooltip: 'Import CSV',
              icon: const Icon(Icons.file_upload),
            ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              controller: _searchController,
              enabled: !_isImporting,
              onChanged: _searchChanged,
              decoration: const InputDecoration(
                labelText: 'Cari nama, PLU, atau barcode',
                prefixIcon: Icon(Icons.search),
                border: OutlineInputBorder(),
              ),
            ),
          ),
          Expanded(child: _buildProducts()),
          SafeArea(
            top: false,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                TextButton(
                  onPressed: canNavigate && _page > 0
                      ? () => _loadProducts(page: _page - 1)
                      : null,
                  child: const Text('Sebelumnya'),
                ),
                Text('Halaman ${_page + 1}'),
                TextButton(
                  onPressed: canNavigate && (_page + 1) * _pageSize < _total
                      ? () => _loadProducts(page: _page + 1)
                      : null,
                  child: const Text('Berikutnya'),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
