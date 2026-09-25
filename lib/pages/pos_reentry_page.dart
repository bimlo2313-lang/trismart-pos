import 'dart:async';

import 'package:barcode_widget/barcode_widget.dart';
import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../models/cash_transaction.dart';

class PosReentryPage extends StatefulWidget {
  PosReentryPage({
    super.key,
    required this.transactionNo,
    required List<Map<String, dynamic>> items,
  }) : items = List.unmodifiable(
         items.map((item) => Map<String, dynamic>.unmodifiable(item)),
       );

  final String transactionNo;
  // Snapshot dari detail transaksi; halaman ini tidak mengakses database.
  final List<Map<String, dynamic>> items;

  @override
  State<PosReentryPage> createState() => _PosReentryPageState();
}

class _PosReentryPageState extends State<PosReentryPage>
    with WidgetsBindingObserver {
  final _processed = <int>{};
  final _scroll = ScrollController();
  int _index = 0;
  bool _askingToExit = false;
  bool _closing = false;
  bool _canPop = false;
  bool _foreground = true;
  bool? _previousWake;
  bool _wakeUnavailable = false;
  Future<void> _wakeOperations = Future<void>.value();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _syncWake();
  }

  Future<void> _syncWake() {
    _wakeOperations = _wakeOperations.then((_) async {
      try {
        _previousWake ??= await WakelockPlus.enabled;
        final active = mounted && !_closing && _foreground;
        await WakelockPlus.toggle(enable: active || _previousWake!);
      } catch (_) {
        if (mounted && !_closing) setState(() => _wakeUnavailable = true);
      }
    });
    return _wakeOperations;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _syncWake();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _closing = true;
    unawaited(_syncWake());
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (_askingToExit || _closing) return;
    _askingToExit = true;
    try {
      if (_processed.length < widget.items.length) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Masih ada barang belum diproses'),
            content: Text(
              '${widget.items.length - _processed.length} barang belum ditandai. '
              'Keluar dari mode input ulang? Penanda proses tidak disimpan.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Lanjutkan'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Keluar'),
              ),
            ],
          ),
        );
        if (!mounted || confirmed != true) return;
      }
      _closing = true;
      await _syncWake();
      if (!mounted) return;
      setState(() => _canPop = true);
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) Navigator.of(context).pop();
    } finally {
      _askingToExit = false;
    }
  }

  void _go(int index) {
    setState(() => _index = index);
    if (_scroll.hasClients) _scroll.jumpTo(0);
  }

  Widget _item() => LayoutBuilder(
    builder: (context, viewport) {
      final item = widget.items[_index];
      final barcode = item['barcode'] as String?;
      final usesPlu = barcode == null || barcode.trim().isEmpty;
      final displayBarcodeValue = usesPlu ? item['kode'] as String : barcode;
      final number = widget.transactionNo;
      final shortNumber = number.length > 8
          ? '...${number.substring(number.length - 8)}'
          : number;
      // Constraints sudah dikurangi AppBar, SafeArea, dan kontrol bawah oleh Column.
      final availableHeight = viewport.maxHeight;
      final width = viewport.maxWidth - 16;
      final innerWidth = width - 24;
      final nameSize = (availableHeight * 0.045).clamp(18.0, 24.0);
      final qtySize = (availableHeight * 0.07).clamp(28.0, 36.0);
      final pluSize = (availableHeight * 0.045).clamp(18.0, 24.0);
      final priceSize = (availableHeight * 0.03).clamp(14.0, 16.0);
      final metaSize = (availableHeight * 0.027).clamp(12.0, 13.0);
      final scaler = MediaQuery.textScalerOf(context);
      TextStyle style(double size, {bool bold = false}) => TextStyle(
        fontSize: size,
        height: 1.2,
        color: Colors.black,
        fontWeight: bold ? FontWeight.bold : FontWeight.normal,
      );
      double height(
        String text,
        double size,
        double maxWidth, {
        int? lines,
        bool bold = false,
      }) {
        final painter = TextPainter(
          text: TextSpan(
            text: text,
            style: style(size, bold: bold),
          ),
          textDirection: Directionality.of(context),
          textScaler: scaler,
          maxLines: lines,
          ellipsis: lines == null ? null : '\u2026',
        )..layout(maxWidth: maxWidth);
        final result = painter.height;
        painter.dispose();
        return result;
      }

      final metadata = 'Transaksi  $shortNumber';
      final position = 'Barang ${_index + 1} / ${widget.items.length}';
      final label = usesPlu ? 'PLU \u2022 Barcode tidak tersedia' : 'BARCODE';
      final price = formatRupiah(item['price'] as int);
      final subtotal = formatRupiah(item['subtotal'] as int);
      final moneyLabelWidth = innerWidth * 0.35;
      final moneyValueWidth = innerWidth - moneyLabelWidth - 8;
      double moneyHeight(String label, String value, {bool bold = false}) =>
          height(label, priceSize, moneyLabelWidth, bold: bold).clamp(
            height(value, priceSize, moneyValueWidth, bold: bold),
            double.infinity,
          );
      Widget moneyRow(String label, String value, {bool bold = false}) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: moneyLabelWidth,
            child: Text(label, style: style(priceSize, bold: bold)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.right,
              style: style(priceSize, bold: bold),
            ),
          ),
        ],
      );
      final halfWidth = (innerWidth - 12) / 2;
      final qtyHeight =
          height('Qty', metaSize, halfWidth) +
          height('${item['qty']}', qtySize, halfWidth, bold: true);
      final pluHeight =
          height('PLU', metaSize, halfWidth) +
          height('${item['kode']}', pluSize, halfWidth, bold: true);
      final productHeight =
          24 +
          height(
            item['nama'] as String,
            nameSize,
            innerWidth,
            lines: 2,
            bold: true,
          ) +
          6 +
          (qtyHeight > pluHeight ? qtyHeight : pluHeight) +
          6 +
          moneyHeight('Harga', price) +
          2 +
          moneyHeight('Subtotal', subtotal, bold: true);
      final metadataHeight = height(metadata, metaSize, width * 0.60, lines: 1)
          .clamp(
            height(position, metaSize, width * 0.40, lines: 1),
            double.infinity,
          );
      final barcodeTextHeight =
          height(displayBarcodeValue, pluSize, innerWidth, bold: true) +
          height(label, metaSize, innerWidth) +
          6;
      final wakeHeight = _wakeUnavailable
          ? height(
                  'Layar tetap aktif tidak tersedia pada perangkat ini.',
                  metaSize,
                  width,
                ) +
                4
          : 0.0;
      // Minimum hanya untuk fallback viewport sangat pendek; layar normal tanpa scroll.
      final minimumHeight =
          16 +
          metadataHeight +
          6 +
          productHeight +
          6 +
          16 +
          barcodeTextHeight +
          72 +
          wakeHeight;
      final contentHeight = availableHeight < minimumHeight
          ? minimumHeight
          : availableHeight;
      final content = SizedBox(
        height: contentHeight,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                height: metadataHeight,
                child: Row(
                  children: [
                    Expanded(
                      flex: 6,
                      child: Tooltip(
                        message: number,
                        child: Text(
                          metadata,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: style(metaSize),
                        ),
                      ),
                    ),
                    Expanded(
                      flex: 4,
                      child: Text(
                        position,
                        textAlign: TextAlign.end,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: style(metaSize),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.white,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      item['nama'] as String,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: style(nameSize, bold: true),
                    ),
                    const SizedBox(height: 6),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('Qty', style: style(metaSize)),
                              Text(
                                '${item['qty']}',
                                style: style(qtySize, bold: true),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text('PLU', style: style(metaSize)),
                              Text(
                                '${item['kode']}',
                                style: style(pluSize, bold: true),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 6),
                    moneyRow('Harga', price),
                    const SizedBox(height: 2),
                    moneyRow('Subtotal', subtotal, bold: true),
                  ],
                ),
              ),
              const SizedBox(height: 6),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, cardSpace) => Align(
                    alignment: Alignment.topCenter,
                    child: SizedBox(
                      width: double.infinity,
                      height: cardSpace.maxHeight.clamp(
                        0.0,
                        145 + barcodeTextHeight + 16,
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Expanded(
                              child: Padding(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                ),
                                child: LayoutBuilder(
                                  builder: (context, space) {
                                    final encoding = Barcode.code128();
                                    if (!encoding.isValid(
                                      displayBarcodeValue,
                                    )) {
                                      return const Center(
                                        child: Text(
                                          'Format barcode tidak didukung. Gunakan PLU/kode.',
                                        ),
                                      );
                                    }
                                    return Center(
                                      child: BarcodeWidget(
                                        barcode: encoding,
                                        data: displayBarcodeValue,
                                        width: space.maxWidth,
                                        height: space.maxHeight.clamp(
                                          0.0,
                                          145.0,
                                        ),
                                        drawText: false,
                                        color: Colors.black,
                                        backgroundColor: Colors.white,
                                        errorBuilder: (_, _) => const Text(
                                          'Barcode tidak dapat ditampilkan. Gunakan PLU/kode.',
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              displayBarcodeValue,
                              textAlign: TextAlign.center,
                              style: style(pluSize, bold: true),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              label,
                              textAlign: TextAlign.center,
                              style: style(metaSize),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              if (_wakeUnavailable)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Text(
                    'Layar tetap aktif tidak tersedia pada perangkat ini.',
                    style: style(metaSize),
                  ),
                ),
            ],
          ),
        ),
      );
      if (availableHeight < minimumHeight) {
        return SingleChildScrollView(controller: _scroll, child: content);
      }
      return content;
    },
  );

  @override
  Widget build(BuildContext context) => PopScope<void>(
    canPop: _canPop,
    onPopInvokedWithResult: (didPop, _) {
      if (!didPop) _finish();
    },
    child: Scaffold(
      backgroundColor: const Color(0xFFF5F8F6),
      appBar: AppBar(
        title: const Text('Input Ulang ke POS'),
        leading: IconButton(
          onPressed: _finish,
          tooltip: 'Kembali',
          icon: const Icon(Icons.arrow_back),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: widget.items.isEmpty
                ? const Center(
                    child: Text('Tidak ada barang dalam transaksi ini.'),
                  )
                : Column(
                    children: [
                      Expanded(child: _item()),
                      const Divider(height: 1),
                      CheckboxListTile(
                        dense: true,
                        activeColor: const Color(0xFF087F3E),
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                        ),
                        title: const Text('Sudah diproses'),
                        value: _processed.contains(_index),
                        onChanged: (value) => setState(() {
                          if (value == true) {
                            _processed.add(_index);
                          } else {
                            _processed.remove(_index);
                          }
                        }),
                        controlAffinity: ListTileControlAffinity.leading,
                      ),
                      Text(
                        '${_processed.length} dari ${widget.items.length} diproses',
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 13),
                      ),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
                        child: Row(
                          children: [
                            Expanded(
                              child: OutlinedButton(
                                style: OutlinedButton.styleFrom(
                                  minimumSize: const Size(0, 48),
                                ),
                                onPressed: _index == 0
                                    ? null
                                    : () => _go(_index - 1),
                                child: const Text('Sebelumnya'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: FilledButton(
                                style: FilledButton.styleFrom(
                                  minimumSize: const Size(0, 48),
                                ),
                                onPressed: _index == widget.items.length - 1
                                    ? _finish
                                    : () => _go(_index + 1),
                                child: Text(
                                  _index == widget.items.length - 1
                                      ? 'Selesai'
                                      : 'Berikutnya',
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
          ),
        ),
      ),
    ),
  );
}
