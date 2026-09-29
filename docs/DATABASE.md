# Database

## CURRENT SQLite database

Authoritative source: `lib/database/database_helper.dart`, inspected at `6ac1441`
on 2026-09-29. File: `kasir.db` under `getDatabasesPath()`. Open version: **5**.
`onConfigure` enables `PRAGMA foreign_keys = ON`. Three application tables exist;
SQLite also manages internal objects such as `sqlite_sequence` for AUTOINCREMENT.

### products

| Column | SQL definition |
| --- | --- |
| id | INTEGER PRIMARY KEY AUTOINCREMENT |
| kode | TEXT NOT NULL UNIQUE |
| barcode | TEXT, nullable |
| nama | TEXT NOT NULL |
| unit | TEXT, nullable |
| harga_jual | REAL DEFAULT 0, nullable |
| stok | REAL DEFAULT 0, nullable |
| lokasi | TEXT, nullable |
| aktif | INTEGER DEFAULT 1, nullable |

`kode` is the PLU/upsert key. Barcode is not unique. Defaults do not imply NOT NULL.
There is no product-to-outlet foreign key; `lokasi` is a plain text field.

### transactions

| Column | SQL definition |
| --- | --- |
| id | INTEGER PRIMARY KEY AUTOINCREMENT |
| transaction_no | TEXT NOT NULL UNIQUE |
| transaction_date | TEXT NOT NULL |
| total | INTEGER NOT NULL |
| payment_method | TEXT NOT NULL |
| amount_paid | INTEGER NOT NULL |
| change_amount | INTEGER NOT NULL |
| status | TEXT NOT NULL DEFAULT 'COMPLETED' |
| outlet_code | TEXT NULL (v5 addition) |
| terminal_code | TEXT NULL (v5 addition) |

New sales store UTC ISO date strings, integer Rupiah, `CASH`, and `COMPLETED`.
Outlet/terminal codes are immutable historical snapshots in normal operation;
legacy rows keep NULL. No outlet or terminal table/FK exists. Transaction numbering
is described in [business rules](BUSINESS_RULES.md).

### transaction_items

| Column | SQL definition |
| --- | --- |
| id | INTEGER PRIMARY KEY AUTOINCREMENT |
| transaction_id | INTEGER NOT NULL; FK to transactions(id) |
| product_id | INTEGER NOT NULL; no FK to products |
| kode | TEXT NOT NULL |
| barcode | TEXT, nullable |
| nama | TEXT NOT NULL |
| unit | TEXT, nullable |
| price | INTEGER NOT NULL |
| qty | INTEGER NOT NULL |
| subtotal | INTEGER NOT NULL |

No ON DELETE/UPDATE cascade is specified. Product identity, description, price,
quantity, and subtotal are snapshots; history must survive master changes/deletion.
There is no unique constraint on transaction/product pairs and no SQL CHECK on
positive quantity, stock, payment method, status, or arithmetic. The normal sale
path enforces its invariants in Dart and guarded SQL; do not assume the schema alone
rejects every invalid direct write.

### Indexes and constraints

| Name | Columns | Kind |
| --- | --- | --- |
| idx_products_barcode | products(barcode) | Non-unique |
| idx_products_nama_id | products(nama, id) | Non-unique |
| idx_transaction_items_transaction_id | transaction_items(transaction_id) | Non-unique |
| idx_transactions_date_id | transactions(transaction_date DESC, id DESC) | Non-unique |

`products.kode` and `transactions.transaction_no` also have SQLite-managed unique
indexes from their UNIQUE declarations. Integer PKs identify rows. No explicit
index on outlet/terminal or `transaction_items.product_id` is created.

### Verified migration chain

| Version | Upgrade behavior in current source |
| --- | --- |
| 1 | Historical product-only baseline implied by upgrade chain |
| 2 | If oldVersion < 2, create barcode and name/ID product indexes |
| 3 | If oldVersion < 3, create transactions/items and item transaction index |
| 4 | If oldVersion < 4, create descending history date/ID index |
| 5 | If oldVersion < 5, add nullable outlet_code and terminal_code to transactions |

Fresh creation builds products, indexes, transaction tables, history index, then
adds identity columns. The migration chain has no DROP, destructive rebuild, or
historical identity backfill. Version 1's original full DDL is not reconstructed
here from assumptions; the tables above describe the current v5 creation path.

### Operational invariants and boundaries

- Finalization is a single DB transaction for number/header/items/stock. Conditional
  decrements and rollback prevent partial sales. Unique numbers prevent collisions,
  but do not provide durable request replay deduplication.
- CSV upserts preserve IDs by PLU and commit per batch, not per entire file.
- Settings live in SharedPreferences (`cashier_identity`); backup history uses
  `last_successful_backup`. Neither is an application SQLite table.
- Backup uses a consistent SQLite snapshot. Restore replaces the whole DB and
  leaves device preferences unchanged; see [architecture](ARCHITECTURE.md).
- Restore validation in `lib/services/restore_validation.dart` currently hardcodes
  version 5 as supported. Any future DB migration must also review backup/restore
  compatibility and tests; never merely bump the opening version.
- There are no sync-state/outbox, stock-movement, user, role, permission, or scope
  tables. Local IDs/transaction numbers are not yet a designed global identity.
- Preserve transaction history and snapshots; migrations must be non-destructive
  unless explicitly approved. Do not silently relabel SMR as KWD.

## FUTURE central PostgreSQL database

**PLANNED / NOT IMPLEMENTED.** No full central schema is designed in this handover.
Intended responsibilities: centralized transactions and items, product master,
prices, stock movements, outlets/terminals, users, roles, permissions, outlet/data
scopes, synchronization state, reporting, and audit. Clients will communicate only
through an authenticated HTTPS API, never directly with PostgreSQL.
