import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/outlet.dart';

class SettingsService {
  static const _key = 'cashier_identity';

  Future<CashierIdentity?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return null;
    try {
      final data = jsonDecode(raw);
      if (data is! Map<String, dynamic>) return null;
      final outlet = data['outletCode'];
      final terminal = data['terminalCode'];
      if (outlet is! String ||
          terminal is! String ||
          outletByCode(outlet) == null ||
          !terminalCodes.contains(terminal)) {
        return null;
      }
      return CashierIdentity(outletCode: outlet, terminalCode: terminal);
    } on FormatException {
      return null;
    }
  }

  Future<void> save({
    required String? outletCode,
    required String? terminalCode,
  }) async {
    if (outletByCode(outletCode)?.active != true ||
        !terminalCodes.contains(terminalCode)) {
      throw ArgumentError('Pilih outlet dan terminal yang valid.');
    }
    final prefs = await SharedPreferences.getInstance();
    // Satu nilai menjaga pasangan outlet/terminal tersimpan bersama.
    final saved = await prefs.setString(
      _key,
      jsonEncode({'outletCode': outletCode, 'terminalCode': terminalCode}),
    );
    if (!saved) throw StateError('Pengaturan gagal disimpan.');
  }
}
