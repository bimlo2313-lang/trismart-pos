# Sync direction

**STATUS: PLANNED / NOT IMPLEMENTED.** This is architectural direction, not an
implemented protocol, API contract, migration, or finalized schema.

## Offline first

Normal sale in the intended system:

```text
scan -> SQLite lookup -> payment -> atomic local commit -> receipt
     -> pending sync -> cashier continues
```

The local cash commit and on-screen receipt summary exist today; pending-sync
storage/processing does not. Internet/server availability must never gate a normal sale.

When connectivity returns, the planned upload path is:

```text
pending transaction -> authenticated HTTPS API
    -> server validates unique identity -> PostgreSQL commit
    -> ACK -> local transaction marked synced
```

Requirements: idempotent and retry-safe processing, no duplicate sale on retry,
observable sync status, retryable failures, incremental synchronization, and no
silent loss of unsynced data. A timeout after server commit must allow a replay
that resolves to the same accepted sale. ACK must reflect durable acceptance;
local data must not be considered synced merely because a request was sent.
Identity allocation, local pending-state representation, scheduling/backoff,
API payloads, acknowledgments, and reconciliation details remain TBD.

## Planned data directions

| Direction | Intended data |
| --- | --- |
| POS -> server | Completed transactions, transaction items, future operational/stock events |
| Server -> POS | Product master, prices, promotions, users/permissions, relevant configuration |
| Potentially bidirectional | Some inventory and operational data; conflict policy not yet designed |

The current CSV import/export and backup/restore workflows are not sync. Human-readable
transaction numbers alone do not establish cross-device uniqueness after cloning,
restore, or duplicate terminal configuration. Global identity and deduplication
must be designed before implementing retries across devices.

## Stock principle

Do not synchronize only `stock = 7` and blindly overwrite another terminal's value.
Prefer auditable movements/events such as:

| Event | Quantity delta |
| --- | --- |
| SALE | -3 |
| RECEIVE | +10 |
| TRANSFER | -5 |
| ADJUSTMENT | +2 |
| RETURN | +1 |

Current SQLite sales decrement a local quantity; a stock movement ledger is future
work. Multiple offline terminals may sell against stale views of the same stock.
Allocation, oversell handling, ordering, duplicate events, transfers, and conflict
resolution are future design problems, not solved by local transaction atomicity.

Authorization must support previously synchronized permissions for offline
cashiers while enforcing API permissions/scopes online. Offline authentication is
TBD; never store plaintext passwords. See [architecture](ARCHITECTURE.md) and
[future validation cases](TESTING.md).
