import 'dart:async';

import 'package:flutter/material.dart';
import 'database/database_helper.dart';
import 'pages/data_barang_page.dart';
import 'pages/transaction_page.dart';
import 'pages/transaction_history_page.dart';
import 'pages/daily_sales_report_page.dart';
import 'pages/settings_page.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();

  final database = DatabaseHelper.instance;

  final initialization = database.database;

  runApp(KasirApp(initialization: initialization));
}

class KasirApp extends StatelessWidget {
  const KasirApp({super.key, this.initialization});

  final Future<void>? initialization;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'TRISMART',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: initialization == null
          ? const DashboardPage()
          : _SplashGate(initialization: initialization!),
    );
  }
}

class _SplashGate extends StatefulWidget {
  const _SplashGate({required this.initialization});

  final Future<void> initialization;

  @override
  State<_SplashGate> createState() => _SplashGateState();
}

class _SplashGateState extends State<_SplashGate> {
  final _minimumVisible = Completer<void>();
  late final Future<List<void>> _ready;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Initialization sudah dimulai di main; tunggu bersamaan, bukan berurutan.
    _ready = Future.wait<void>([widget.initialization, _minimumVisible.future]);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      // Hitung durasi branding setelah frame Flutter splash pertama dirender.
      _timer = Timer(const Duration(milliseconds: 1500), () {
        _minimumVisible.complete();
      });
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<List<void>>(
    future: _ready,
    builder: (context, snapshot) {
      if (snapshot.connectionState == ConnectionState.done &&
          !snapshot.hasError) {
        return const DashboardPage();
      }
      return _BrandSplash(failed: snapshot.hasError);
    },
  );
}

class _BrandSplash extends StatelessWidget {
  const _BrandSplash({required this.failed});

  final bool failed;

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Colors.white,
    body: SafeArea(
      child: Column(
        children: [
          Expanded(
            child: SizedBox.expand(
              child: Image.asset(
                'assets/branding/splash_trismart.png',
                fit: BoxFit.contain,
                excludeFromSemantics: true,
              ),
            ),
          ),
          if (failed)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text(
                'Aplikasi belum dapat dibuka. Silakan tutup dan buka kembali.',
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    ),
  );
}

class DashboardPage extends StatelessWidget {
  const DashboardPage({super.key});

  static const _green = Color(0xFF087F3E);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        fit: StackFit.expand,
        children: [
          Image.asset(
            'assets/branding/home_background_trismart.png',
            fit: BoxFit.cover,
            excludeFromSemantics: true,
          ),
          SafeArea(
            child: LayoutBuilder(
              builder: (context, constraints) => SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: Center(
                    child: ConstrainedBox(
                      constraints: BoxConstraints(
                        maxWidth: 760,
                        minHeight: constraints.maxHeight,
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(20),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const _HomeHeader(),
                                const SizedBox(height: 16),
                                LayoutBuilder(
                                  builder: (context, grid) {
                                    final textScale =
                                        MediaQuery.textScalerOf(
                                          context,
                                        ).scale(14) /
                                        14;
                                    final columns =
                                        grid.maxWidth < 260 || textScale > 1.5
                                        ? 1
                                        : 2;
                                    final width =
                                        (grid.maxWidth - 14 * (columns - 1)) /
                                        columns;
                                    return Wrap(
                                      spacing: 14,
                                      runSpacing: 14,
                                      children: [
                                        _menuButton(
                                          context,
                                          width: width,
                                          icon: Icons.point_of_sale_rounded,
                                          title: 'Transaksi',
                                          subtitle: 'Mulai transaksi',
                                          color: _green,
                                          onTap: () => Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  const TransactionPage(),
                                            ),
                                          ),
                                        ),
                                        _menuButton(
                                          context,
                                          width: width,
                                          icon: Icons.inventory_2_outlined,
                                          title: 'Data Barang',
                                          subtitle: 'Kelola master barang',
                                          color: const Color(0xFF936300),
                                          onTap: () => Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  const DataBarangPage(),
                                            ),
                                          ),
                                        ),
                                        _menuButton(
                                          context,
                                          width: width,
                                          icon: Icons.receipt_long_outlined,
                                          title: 'Riwayat',
                                          subtitle: 'Lihat transaksi',
                                          color: const Color(0xFFC32E35),
                                          onTap: () => Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  const TransactionHistoryPage(),
                                            ),
                                          ),
                                        ),
                                        _menuButton(
                                          context,
                                          width: width,
                                          icon: Icons.bar_chart_rounded,
                                          title: 'Laporan',
                                          subtitle: 'Penjualan harian',
                                          color: _green,
                                          onTap: () => Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  const DailySalesReportPage(),
                                            ),
                                          ),
                                        ),
                                        _menuButton(
                                          context,
                                          width: width,
                                          icon: Icons.settings_outlined,
                                          title: 'Pengaturan',
                                          subtitle:
                                              'Identitas outlet & terminal',
                                          color: _green,
                                          onTap: () => Navigator.push(
                                            context,
                                            MaterialPageRoute(
                                              builder: (_) =>
                                                  const SettingsPage(),
                                            ),
                                          ),
                                        ),
                                      ],
                                    );
                                  },
                                ),
                              ],
                            ),
                            const Padding(
                              padding: EdgeInsets.only(top: 20, bottom: 4),
                              child: _BrandCredit(),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _menuButton(
    BuildContext context, {
    required double width,
    required IconData icon,
    required String title,
    required String subtitle,
    required Color color,
    required VoidCallback? onTap,
  }) => SizedBox(
    width: width,
    child: Card(
      margin: EdgeInsets.zero,
      color: Colors.white.withValues(alpha: 0.96),
      surfaceTintColor: Colors.transparent,
      elevation: 2,
      shadowColor: Colors.black.withValues(alpha: 0.12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          child: Column(
            children: [
              Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.10),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Icon(icon, size: 28, color: color),
              ),
              const SizedBox(height: 10),
              Text(
                title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF203B2B),
                ),
              ),
              const SizedBox(height: 5),
              Text(
                subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 12, color: Color(0xFF59685F)),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}

class _HomeHeader extends StatelessWidget {
  const _HomeHeader();

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.96),
      borderRadius: BorderRadius.circular(18),
      boxShadow: const [
        BoxShadow(
          color: Color(0x0A000000),
          blurRadius: 8,
          offset: Offset(0, 2),
        ),
      ],
    ),
    child: LayoutBuilder(
      builder: (context, constraints) {
        const identity = Text(
          'TRISMART',
          style: TextStyle(
            color: Color(0xFF087F3E),
            fontSize: 21,
            fontWeight: FontWeight.w900,
            letterSpacing: 0.5,
          ),
        );
        const description = Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Sistem Kasir',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: Color(0xFF203B2B),
              ),
            ),
            SizedBox(height: 2),
            Text(
              'Cepat • Mudah • Terpercaya',
              style: TextStyle(fontSize: 11, color: Color(0xFF59685F)),
            ),
          ],
        );
        if (constraints.maxWidth < 270 ||
            MediaQuery.textScalerOf(context).scale(14) > 21) {
          return const Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [identity, SizedBox(height: 6), description],
          );
        }
        return const Row(
          children: [
            identity,
            SizedBox(width: 14),
            Expanded(child: description),
          ],
        );
      },
    ),
  );
}

class _BrandCredit extends StatelessWidget {
  const _BrandCredit();

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    decoration: BoxDecoration(
      color: Colors.white.withValues(alpha: 0.95),
      borderRadius: BorderRadius.circular(16),
      boxShadow: const [
        BoxShadow(
          color: Color(0x08000000),
          blurRadius: 6,
          offset: Offset(0, 2),
        ),
      ],
    ),
    child: const Column(
      children: [
        Text.rich(
          TextSpan(
            children: [
              TextSpan(text: 'Developed By ', style: TextStyle(fontSize: 12)),
              TextSpan(
                text: 'Bimz',
                style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
              ),
            ],
          ),
          textAlign: TextAlign.center,
          style: TextStyle(color: Color(0xFF203B2B)),
        ),
        SizedBox(height: 3),
        Text(
          'IT SUPPORT',
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 2.5,
            color: Color(0xFF59685F),
          ),
        ),
      ],
    ),
  );
}
