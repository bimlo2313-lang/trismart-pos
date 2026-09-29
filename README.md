# TRISMART POS

Flutter POS for Android and Windows, with local SQLite sales. Originally a fallback
POS, its long-term direction is replacement of the existing company POS.

Current source baseline: app `1.0.1+2`, SQLite version 5. Server synchronization,
Django/PostgreSQL, and centralized roles/permissions are planned, not implemented.

Routine Android development must use **TRISMART POS DEV** (`com.trismart.pos.dev`,
debug). Protect production **TRISMART POS** (`com.trismart.pos`) and its data.

## Project documentation

- [Agent instructions](AGENTS.md)
- [Architecture and planned authorization](docs/ARCHITECTURE.md)
- [Business rules](docs/BUSINESS_RULES.md)
- [Database](docs/DATABASE.md)
- [Planned sync direction](docs/SYNC_DESIGN.md)
- [Roadmap and converter status](docs/ROADMAP.md)
- [Testing](docs/TESTING.md)

## Getting Started

Read the project documentation above before making changes. General Flutter
resources from the original README are retained below.

A few resources to get you started if this is your first Flutter project:

- [Learn Flutter](https://docs.flutter.dev/get-started/learn-flutter)
- [Write your first Flutter app](https://docs.flutter.dev/get-started/codelab)
- [Flutter learning resources](https://docs.flutter.dev/reference/learning-resources)

For help getting started with Flutter development, view the
[online documentation](https://docs.flutter.dev/), which offers tutorials,
samples, guidance on mobile development, and a full API reference.
