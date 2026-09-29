# Testing and validation

## Baseline and normal workflow

Project-owner baseline before this documentation task: **120 Flutter tests PASS**.
This is a reported prior result, not a test run performed by the documentation task.
Test counts can increase; report actual counts/results from each subsequent run.
Source/test inspection baseline: 2026-09-29, `6ac1441`.

Before changes inspect `git status --short`; preserve any existing dirty work.
Read relevant source/tests, run targeted tests for changed behavior, then:

```powershell
flutter analyze
flutter test
git diff --check
```

Run the full suite when appropriate to behavior/schema/platform changes. Report
failures and environment limitations accurately. For Markdown-only work, Flutter
analysis/tests are unnecessary unless source/configuration was accidentally changed;
check diffs, documentation links, and source consistency instead.

## Critical regressions and existing test map

| Area | Existing test files / validation focus |
| --- | --- |
| Barcode, PLU, one-leading-zero equivalence | `test/barcode_lookup_test.dart`: exact priority, one-zero bounds, trim, fallback |
| Name search / USB submissions | `test/transaction_name_search_test.dart`: debounce, active-only results, exact-code priority, queued scans |
| Money/cart validation | `test/cash_transaction_test.dart`: snapshots, invalid items, overflow |
| Atomicity/stock/identity/legacy | `test/transaction_identity_test.dart`: missing identity, rollback and snapshot compatibility |
| Numbering and double submission | `test/transaction_number_test.dart`: per-prefix sequence, concurrency, collision/shortage rollback, six-digit limit, UI guards |
| Outlet settings | `test/settings_test.dart`: fixed catalog, no default, persistence and validation |
| History/detail/daily report | Identity/number tests plus `test/daily_sales_report_test.dart`: historical snapshots, day boundaries and completed sales |
| Input Ulang ke POS | `test/pos_reentry_ui_test.dart`: snapshot barcode/PLU, local progress, layout |
| Backup | `test/backup_test.dart`: snapshot/export results and UI |
| Restore | `test/restore_test.dart`: malformed packages, version/schema/integrity, preview/cancel, replace/rollback and retained settings |
| CSV export | `test/transaction_export_test.dart`, `test/transaction_export_ui_test.dart`: date ranges, all statuses, snapshots, leading zeros, NULL legacy identity, save/cancel/locking |
| Startup UI | `test/branding_test.dart`: splash initialization and responsive dashboard |

The map describes existing tests; it does not assert complete coverage of every
failure path. Any change to stock handling must check decrements, insufficient-stock
rollback, item/header persistence, and snapshot independence from master changes.
Inspect CSV import's per-batch transaction boundary when changing import behavior.

## Platform/device validation

Android routine testing must use `com.trismart.pos.dev` / **TRISMART POS DEV**.
Use `flutter run --debug -d <android-device-id>` and verify the installed identity.
The debug suffix/label are configured in Gradle; manifest uses `${appLabel}`.
Profile/release have no explicit DEV isolation in current configuration. Do not
uninstall, clear, or overwrite production `com.trismart.pos` / **TRISMART POS**.
Check coexistence and separate data without altering production transactions.
Release signing/build verification is separate, authorized release work; never
print signing secrets.

For Windows, inspect `main()`'s Windows-only `sqfliteFfiInit()` and
`databaseFactoryFfi` assignment before DB opening. Smoke-test `flutter run -d windows`
with test data, DB reopen, lookup/cash sale/history, and required file dialogs/hardware.
Existing FFI-backed database tests do not prove the Windows startup branch or full
hardware behavior works. Test camera availability/permission, USB input, audio,
and backup/restore/export on the actual target platform as relevant. No dedicated
Windows initialization or Android package-isolation test file was found in `test/`;
these need platform/configuration checks in addition to the Flutter suite.

## FUTURE sync testing / NOT IMPLEMENTED

Eventually cover offline sales, reconnect, retry, duplicate upload, timeout after
server commit, unavailable server, unsynced data preservation, multiple terminals,
and conflicting inventory movements. Include authorization/scopes online and
offline once designed. A current local double-submit test is not a network
idempotency test.

Windows 7 converter status remains PENDING. Follow the limitations and workaround
in [roadmap](ROADMAP.md); do not treat local Windows 10 packaging tests as Windows 7 PASS.
