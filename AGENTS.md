# TRISMART POS: agent handover

TRISMART is a Flutter POS application, originally a fallback POS. Its long-term
direction is to replace the current company POS. Read this file first, then the
relevant [documentation](README.md). Source code is authoritative for current behavior.

## Architecture

CURRENT: Flutter Android + Windows -> local SQLite. Normal sales must remain
locally operable. Verified baseline on 2026-09-29: app `1.0.1+2`, SQLite version 5.

PLANNED / NOT IMPLEMENTED: Flutter Android + Windows -> local SQLite -> Sync
Engine -> HTTPS -> Django REST API -> centralized PostgreSQL. Centralized users,
roles, permissions, and outlet/data scopes are also planned.

## Non-negotiable rules

- Sales must work without internet/server. Preserve existing data and history.
- Migrations must be non-destructive unless explicitly approved.
- Finalization must stay atomic; failures must not partially change stock/history.
- Retries must not duplicate sales. Preserve current double-submit guards; do not
  mistake them for durable idempotency (see [business rules](docs/BUSINESS_RULES.md)).
- Preserve historical outlet identity. SMR/Sumberejo and KWD/Kawedusan are distinct;
  never silently rename historical transactions or remove inactive outlet history.
- Preserve barcode equivalence differing by one leading zero. Never strip all zeros.
- Transaction snapshots must not depend on current product master data.
- Do not silently change production behavior.
- Future clients must never connect directly to PostgreSQL. Use authenticated APIs.
- Future sync must be idempotent, retry-safe, and preserve unsynced data.
- Future stock sync should use auditable movements/events, not blind quantity overwrites.
- Never expose credentials, passwords, signing properties, or keystore secrets.

## Android safety

| Use | Package | Display name |
| --- | --- | --- |
| Production | `com.trismart.pos` | TRISMART POS |
| Development (debug) | `com.trismart.pos.dev` | TRISMART POS DEV |

Routine Android `flutter run`/testing MUST target DEV; protect the production app
and its data. Debug uses `applicationIdSuffix = ".dev"` and the `appLabel` manifest
placeholder. Use debug mode explicitly; profile/release have no explicit DEV
suffix in current configuration. Never uninstall/clear production data for testing.

## Workflow

1. Read `AGENTS.md` and relevant `docs/`.
2. Inspect relevant source and git status before editing.
3. Scope changes to the requested stage; preserve unrelated/uncommitted work.
4. Run targeted tests, then `flutter analyze`; run full `flutter test` when appropriate.
   Documentation-only changes need `git diff --check`, not a Flutter run.
5. Report files changed, DB version/schema impact, and validation results/limitations.
6. Never commit, push, or tag unless explicitly requested.

Start with [architecture](docs/ARCHITECTURE.md), [business rules](docs/BUSINESS_RULES.md),
[database](docs/DATABASE.md), and [testing](docs/TESTING.md). Future work follows the
[roadmap](docs/ROADMAP.md) and [planned sync direction](docs/SYNC_DESIGN.md).
