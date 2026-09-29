# Architecture

Source inspection baseline: 2026-09-29, commit `6ac1441` (Android development/production
separation), app `1.0.1+2`. Working tree was clean and HEAD matched the locally known
`origin/master` (0 ahead/0 behind); no remote fetch was performed.

## CURRENT architecture

```text
Flutter UI (Android + Windows)
    -> Dart database/services
    -> SQLite local (kasir.db, version 5)
Settings -> SharedPreferences (separate from SQLite)
```

Sales are local. There is no implemented Sync Engine, Django API, PostgreSQL
connection, or centralized authorization system in this application.

| Responsibility | Source and behavior |
| --- | --- |
| Startup/navigation | `lib/main.dart`: database initialization, splash gate, dashboard |
| Product master | `lib/database/database_helper.dart`, `lib/pages/data_barang_page.dart`: local products, listing/search; `lib/services/import_service.dart`: CSV import |
| Sales | `lib/pages/transaction_page.dart`, `cash_payment_dialog.dart`, `lib/models/cash_transaction.dart`: in-memory cart, snapshots, integer Rupiah, cash payment |
| Atomic persistence | `DatabaseHelper.completeCashTransaction`: header/items and guarded stock decrement in one SQLite transaction |
| Scanning | `lib/pages/barcode_scanner_page.dart`: `mobile_scanner` camera flow and audio feedback; transaction input accepts manual/USB keyboard submissions through a queue |
| Identity/settings | `lib/models/outlet.dart`, `lib/services/settings_service.dart`, `lib/pages/settings_page.dart`: fixed outlet/terminal options; SharedPreferences `cashier_identity` JSON |
| History/detail | `transaction_history_page.dart`, `transaction_detail_page.dart`: persisted header/item snapshots; history filters and pagination |
| Input Ulang ke POS | `pos_reentry_page.dart`: displays snapshot barcode or PLU fallback for re-entry into the existing POS; progress is session-local, no DB writes or automatic integration |
| Reports | `daily_sales_report_page.dart`, `DatabaseHelper.getDailySalesReport`: local-day completed sales, totals/average/quantity, transactions and product aggregates from snapshots |
| Backup/restore | `backup_service.dart`, `restore_service.dart`, `restore_validation.dart`, `data_transfer_lock.dart`; settings UI in `backup_section.dart` |
| Export | `transaction_export_service.dart`, `backup_section.dart`: date-range ZIP containing transaction and item CSV files |

Page filenames without a directory above are under `lib/pages/`; service filenames
are under `lib/services/`. Dependencies and declared versions are in `pubspec.yaml`;
the Dart SDK constraint is `^3.12.2`. No dependency change is part of this handover.

### Backup, restore, and export boundaries

Backup uses SQLite `VACUUM INTO` for a consistent snapshot, including committed WAL
data. A `.trismart` ZIP contains `database.sqlite` and `metadata.json`, format version
1, DB version, origin identity, counts, timestamp, and SHA-256. It is not an encrypted
backup or a full SharedPreferences backup. Last successful backup metadata is stored
separately in preferences.

Restore previews/validates the package, requires UI confirmation, revalidates before
replacement, creates a safety snapshot, and replaces the entire database rather than
merging. Current validation accepts only DB version 5. It checks archive bounds,
entry names, checksum, SQLite integrity/schema and foreign keys. Device settings and
last-backup preferences remain unchanged. A replacement failure attempts rollback;
failed rollback retains recovery files and blocks DB access. A `.restore-pending`
marker also blocks normal startup until recovery is resolved. Do not delete it to
bypass the protection.

Export produces `TRISMART_Export_YYYYMMDD_YYYYMMDD.zip` with `transactions.csv` and
`transaction_items.csv`: UTF-8 BOM, quoted text, integer monetary values, local date
display, inclusive local-day range, and all statuses. It reads stored snapshots and
does not mark rows synced. The two SELECTs are not wrapped in a shared read transaction;
do not describe export as the same consistency mechanism as backup. UI transfer locking
coordinates backup/restore/export. Export is not a restore package or a sync protocol.

### Android

`android/app/build.gradle.kts` declares namespace/application ID `com.trismart.pos`.
Debug adds `.dev` and label `TRISMART POS DEV`; production label is `TRISMART POS`.
`android/app/src/main/AndroidManifest.xml` uses `${appLabel}`, requests camera permission
with optional camera hardware, and disables Android automatic backup. Routine Android
development must use DEV/debug and preserve production data.

Release signing configuration requires local credentials and a keystore, with a
pre-release validation task and no debug-signing fallback. This is source-confirmed
configuration, not a new release-build or signing verification. Never copy secrets
into documentation. Gradle uses Java 17; SDK values come from Flutter. Android
`MainActivity.kt` implements the `trismart/backup` method channel for native document
open/save of backups and CSV export ZIPs.

### Windows

Before opening the database, `lib/main.dart` checks
`defaultTargetPlatform == TargetPlatform.windows`, calls `sqfliteFfiInit()`, and
sets `databaseFactory = databaseFactoryFfi`. Other platforms do not take this branch.
`sqflite_common_ffi` is declared in `pubspec.yaml`; Windows runner/CMake files exist
and the executable name remains `kasir_app`.

The project owner reports a successful Windows application run; commit `837d28b`
records the initialization fix. This handover verifies source, not a fresh device
run. Windows production feature completeness and camera/hardware compatibility
are not established by startup alone. Validate each required device workflow.

## PLANNED architecture / NOT IMPLEMENTED

```text
Flutter Android + Windows
    -> SQLite local
    -> Sync Engine
    -> HTTPS
    -> Django REST API
    -> PostgreSQL centralized database
```

The server coordinates company data, but internet/server availability must never
be required to complete a normal cashier sale. Clients must not connect directly
to PostgreSQL: database credentials in distributed clients, bypassed authorization,
and direct schema coupling would undermine controlled access and evolution. The
authenticated API will own validation, authorization, idempotency, and central commits.
See [sync direction](SYNC_DESIGN.md); no endpoints or central schema are finalized.

### PLANNED users, roles, permissions, and scopes

One application will use `USER -> ROLE -> PERMISSION -> DATA/OUTLET SCOPE`.
Role answers **what may the user do?** Scope answers **which outlet/data may the
user access?** Cashier, Supervisor, Outlet Admin, and Central Admin are example
roles only, not finalized definitions.

Illustrative permission names: `transaction.create`, `transaction.void`,
`transaction.return`, `product.view`, `product.change_price`, `stock.view`,
`stock.adjust`, `shift.close`, `report.sales`, `user.manage`. These names are not a
final schema or implemented checks.

Menu visibility alone is not security. Future permissions must be enforced in
the UI/action layer and by the server API when online. Previously synchronized
authorization information should permit authorized cashier operation offline.
Never store plaintext passwords locally. Exact offline authentication, expiry,
revocation, and conflict rules remain TBD. Current outlet/terminal identity is
device configuration, not user authentication or authorization.
