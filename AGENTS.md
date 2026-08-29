<!-- road-atlas -->
> **Cross-repository state lives in `../road-atlas`.** Before starting, read its `INDEX.md` and any
> open ledger entry naming this repository. Findings that change what another repo should do belong
> there, not only here. This file still governs how you work inside this repository.
<!-- /road-atlas -->

# AGENTS.md

Instructions for coding agents working in this repository.

## What this is, and who depends on it

`sql-runner` is a small, auditable SQLcl runner: it runs project SQL through saved SQLcl
connections, writes structured logs under `logs/<env>/runs`, extracts an `INTENT` block from each
script, and indexes run history into SQLite.

**The log files are the source of truth. The SQLite database is a rebuildable query surface.**

It is an upstream dependency, not an application. It is installed into the ROAD repositories as
`skills/sql-runner`, so a change here reaches road-kit, road-cal, road-blogger and quorate — each
of which holds its own installed copy. Changing the runner changes how every one of those repos
executes and audits SQL.

One repository, `aida`, still runs a stale fork of an older runner in its own `bin/` rather than
an installed copy. That is tracked as `L-02` in the atlas.

## Cross-repository state

Read `../road-atlas/INDEX.md` before changing anything here, and check which repositories are
listed as consumers.
