# Quotient Core

Quotient collects usage and quota information from several AI coding services,
shows it in a macOS menu bar app, and can coordinate opt-in coding tasks across
your own Macs. This repository contains the macOS core, CLI, and menu bar app.
The companion iPhone app is maintained in a separate Quotient Mobile source
repository.

## Build and test

Requirements: macOS 14 or newer, Xcode Command Line Tools with Swift 6.0 or
newer. No third-party package manager is required.

```sh
swift build
swift test
swift run llmq --help
```

Build and tests do not require API keys. Configure providers and unattended task
execution only after reviewing the local security model in `SECURITY.md`.
Running agents can spend provider quota and modify repositories you explicitly
register. No provider account, signing identity, cluster key, task ledger, or
personal QA log is included in this source snapshot.

## Scope and maturity

Quota collection, display, and task coordination are usable but depend on the
provider's current APIs and your local credentials. Complex project delivery,
especially end-to-end game production, remains experimental. A green build or
agent-completed task does not prove a playable or production-ready result.

This is a history-free source snapshot. `SOURCE-MANIFEST.json` records the
private source commit and the exact hashes of included files. It deliberately
does not include the private repository's QA history or machine-specific data.

See `CONTRIBUTING.md` for changes and `THIRD_PARTY_NOTICES.md` for bundled code.
