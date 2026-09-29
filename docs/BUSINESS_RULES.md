# Business rules

Current behavior below is derived from `lib/database/database_helper.dart`,
`lib/models/`, `lib/services/import_service.dart`, `settings_service.dart`, and
the transaction pages, inspected at `6ac1441` on 2026-09-29. Policy requirements
and future directions are explicitly identified.

## Outlet and terminal identity

| Code | Name | Current catalog state |
| --- | --- | --- |
| DKO | Doko | Active |
| SMR | Sumberejo | Active |
| GRH | Gurah | Active |
| KWD | Kawedusan | Active |

Stable business policy: SMR and KWD are distinct historical identities. Kawedusan
may operationally replace/relocate Sumberejo, but historical SMR transactions
remain SMR. Never silently rename/delete inactive outlets from history. Current
source lists all four as active; it does not encode an SMR closure.

Current terminal choices are `TERM-01` and `TERM-02`. No default identity is silently
assigned. Settings validate both choices and store the pair together as JSON in
SharedPreferences. Finalization requires configured identity and an active outlet.
New headers snapshot `outlet_code` and `terminal_code`; changing settings does not
rewrite existing headers. Names are resolved from the fixed catalog; there are no
outlet-name/terminal-name snapshot columns. Keep historical catalog mappings stable.

### Transaction numbers

Current format: `{OUTLET}-{TERMINAL_NO}-{YYYYMMDD}-{SEQUENCE_6}`, for example
`KWD-01-20260925-000001`. `TERM-01` contributes `01`.

Within the finalization transaction, one clock value supplies the local calendar
day for the number and the UTC ISO timestamp for `transaction_date`. The next number
is the maximum existing number for the exact outlet/terminal/day prefix plus one;
only exactly six ASCII suffix digits qualify. Empty prefix history starts at
`000001`; legacy/malformed numbers are ignored. Sequence is separate per prefix,
continues after restart from stored rows, and stops at `999999`. Rollback does not
consume a sequence. There is no separate counter table or cross-device allocator.
Do not delete history to reset numbering or assume independent databases with the
same identity cannot collide.

## Product lookup and scanners

- Barcode lookup trims input, prefers an exact match, then tries removing one
  leading zero (if present and length > 1), then adding one leading zero. It never
  repeatedly strips zeros. Duplicate matching barcodes select the lowest product ID.
- Transaction lookup tries barcode first, then exact `kode` (PLU). PLU lookup does
  not apply barcode zero equivalence. Name selection re-looks up by PLU.
- Direct barcode/PLU DB helpers do not filter active state; the cart rejects
  products where `aktif != 1`. Finalization checks active state again.
- Transaction name suggestions use a 300 ms debounce, at least two characters,
  and non-numeric input. Exact barcode/PLU matches take priority. SQLite partial
  `nama LIKE` search escapes `%`, `_`, and backslash, returns active products only,
  sorts by name then ID, and caps results at 20. Do not assume full Unicode case folding.
- Master browsing searches name/PLU/barcode and does not apply the transaction
  active-only filter. A zero-stock product can enter the cart; payment validates stock.
- Camera scanning uses `mobile_scanner`; USB keyboard-style scans submit through
  the normal input queue. Manual, USB, and camera additions share cart lookup logic.
  Hardware/platform support requires device testing, especially Windows camera use.

## CSV master import

Required case-insensitive, trimmed headers: `Kode`, `Nama`, `Qty`, `Unit`,
`Hrg Sat 1`, `Barcode 1`. Parsing runs in a background isolate; UTF-8 BOM is removed.
Rows without code/name are skipped. Code/barcode normalization trims values and
removes numeric `.0` suffixes; barcode normalization additionally removes at most
one leading zero. Empty barcode becomes NULL. Numeric parsing removes commas and
uses zero if parsing fails. Preserve identifiers when preparing safe CSV files.

Import uses `ON CONFLICT(kode) DO UPDATE`, preserving existing product IDs. Imported
fields replace barcode/name/unit/price/**stock**/location/active values; parser sets
`lokasi = 'DOKO'` and `aktif = 1`. This location is not the selected outlet identity.
Absent products are not deleted. Repeated PLUs update the same row in input order.

Batches contain up to 500 products. Each batch is one SQLite transaction with
`continueOnError: false`; the whole CSV is **not** one transaction. Earlier batches
remain committed if a later batch fails. The generic error result may report zero
imports despite prior committed batches. Current import overwrites local quantities;
it is not the future stock-movement sync design.

## Cash transactions and history

The cart snapshots product ID, PLU, barcode, name, unit, and price when first added;
master REAL prices are rounded once to integer Rupiah. Quantities are positive
integers. `transactionTotal` rejects empty/invalid carts, duplicate product IDs,
and unsafe integer totals; maximum exact value is `9007199254740991`. Payment is
currently `CASH`, with amount paid at least total, and change calculated locally.

`completeCashTransaction` atomically inserts a `COMPLETED` header, conditionally
decrements each product's stock, and inserts item snapshots. Updates require matching
ID and PLU, `aktif = 1`, and sufficient stock. Any shortage, missing/inactive product,
or insertion failure rolls back header, items, and all stock updates. The UI keeps
the cart after failure and shows the receipt summary only after successful commit.
This is not a claim of implemented receipt printer integration.

Retry policy: a failed finalization must be safe to retry without a duplicate sale.
Current safeguards are rollback, unique transaction numbers, and payment-dialog
guards against double submission or submission after its receipt exists. The DB
method does **not** accept a durable idempotency key: calling it again after an
already successful commit creates a new sale/number. General replay/crash recovery
idempotency is not implemented; future retry/sync work must address that boundary.

History/items/reporting use persisted snapshots, not a join to current products.
`transaction_items.product_id` is a reference value, not a product FK. Legacy
transaction numbers remain unchanged, and pre-v5 outlet/terminal fields remain
NULL rather than being backfilled from current settings. UI/detail tolerate missing
identity; export writes blank identity cells.

Daily reports include only `COMPLETED` sales and interpret the chosen day locally,
with UTC boundaries for stored dates. Transaction export includes all statuses in
its date range. Input Ulang ke POS uses immutable historical items, renders barcode
or PLU fallback, and tracks re-entry progress only in memory; it does not create
another local sale or decrement stock again.

## PLANNED policies

Sync, stock events, users, roles, permissions, and outlet/data scope are not
implemented. See [architecture](ARCHITECTURE.md) for the authorization direction
and [sync design](SYNC_DESIGN.md) for retry and inventory principles.
