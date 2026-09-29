# Roadmap

TRISMART began as a fallback POS. The long-term milestone is replacement of the
existing company POS. No arbitrary delivery dates are assigned.

## CURRENT / source-confirmed

Inspected on 2026-09-29 at `6ac1441`; these are implementation findings, not claims
that every workflow has passed fresh production/device validation.

| Capability | Evidence |
| --- | --- |
| SQLite product master and CSV upsert import | `database_helper.dart`, `import_service.dart` |
| Barcode/PLU, one-zero equivalence, product-name search | DB lookup methods, `transaction_page.dart` |
| Camera and USB keyboard-style scanner paths | `barcode_scanner_page.dart`, queued transaction submissions |
| Cash sale, atomic stock decrement, history/detail | `completeCashTransaction`, payment/history/detail pages |
| Input Ulang ke POS | `pos_reentry_page.dart`, historical snapshots and session-local progress |
| Daily sales report | `getDailySalesReport`, `daily_sales_report_page.dart` |
| Outlet/terminal settings, snapshots, readable transaction numbers | `outlet.dart`, `settings_service.dart`, DB finalization |
| Backup/restore | Backup/restore services, validation, settings UI |
| Transaction CSV export ZIP and save UI | `transaction_export_service.dart`, `backup_section.dart` |
| Android release signing configuration and DEV/production separation | `android/app/build.gradle.kts`, manifest label placeholder |
| Windows SQLite initialization/runner support | `lib/main.dart`, `sqflite_common_ffi`, `windows/` |

Source paths and current limitations are detailed in [architecture](ARCHITECTURE.md)
and [business rules](BUSINESS_RULES.md). No receipt-printer integration, server sync,
or centralized user authorization is claimed. Windows startup support is not
evidence of complete Windows production/hardware readiness.

## Staged direction

| Phase | Status | Scope |
| --- | --- | --- |
| A | Completed by this documentation task | Permanent documentation and AI handover |
| B | FUTURE | Pilot and feature gap analysis against current company POS |
| C | FUTURE | Complete/stabilize required local POS functionality |
| D | FUTURE | Prepare local data model for synchronization |
| E | FUTURE | TRISMART Server: Django REST API + PostgreSQL |
| F | FUTURE | Sync Engine stage 1: completed transaction upload |
| G | FUTURE | Central product master and price synchronization |
| H | FUTURE | Stock Movement architecture |
| I | FUTURE | Multi-terminal / multi-outlet synchronization |
| J | FUTURE | Centralized User + Role + Permission + Outlet Scope |
| K | FUTURE | Required retail/POS capabilities after gap analysis |
| L | FUTURE | Owner/admin dashboard and advanced reporting |

Phase K may include shift/open-close cash, multiple payment methods, void, returns,
hold/resume, promotions/vouchers, goods receiving, transfers, stock opname, stock
adjustments, and roles/audit. These remain future until implemented and verified.
Phases are planning direction, not permission to expand an individual coding task.

## Master converter operational status

The modern converter can be used on a compatible Windows computer (project-owner
operational context). Windows 7 compatibility remains **PENDING**, not PASS.
Actual Windows 7 testing encountered native Python loading failures: `_socket`,
and later `_tkinter` (the latter supplied in the handover request).

Existing [WIN7_BUILD.md](../tools/master_converter/WIN7_BUILD.md) records the original
device failure; [WIN7_TEST2.md](../tools/master_converter/WIN7_TEST2.md) records local
Windows 10 success and a device-test candidate. Its pending next-step text predates
the reported later `_tkinter` failure. Local success does not establish Windows 7
support. Workaround: convert on another compatible computer and transfer the safe
CSV for POS import. Converter code and historical build notes are unchanged here.
