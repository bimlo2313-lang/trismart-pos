class Outlet {
  const Outlet({required this.code, required this.name, this.active = true});

  final String code;
  final String name;
  final bool active;
}

const outlets = <Outlet>[
  Outlet(code: 'DKO', name: 'Doko'),
  Outlet(code: 'SMR', name: 'Sumberejo'),
  Outlet(code: 'GRH', name: 'Gurah'),
  Outlet(code: 'KWD', name: 'Kawedusan'),
];

Outlet? outletByCode(String? code) {
  for (final outlet in outlets) {
    if (outlet.code == code) return outlet;
  }
  return null;
}

const terminalCodes = ['TERM-01', 'TERM-02'];

class CashierIdentity {
  const CashierIdentity({required this.outletCode, required this.terminalCode});

  final String outletCode;
  final String terminalCode;
  Outlet? get outlet => outletByCode(outletCode);
  String get deviceIdentity => '$outletCode-$terminalCode';
}
