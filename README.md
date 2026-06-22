# sql-runner

Small, auditable SQLcl runner for Oracle Database projects.

It runs project SQL scripts through saved SQLcl connections, writes structured logs under `logs/<env>/runs`, extracts an `INTENT` block from each script, and indexes run history into SQLite when `sqlite3` is available.

## Requirements

- Bash
- Oracle SQLcl available as `sql` on `PATH`
- `sqlite3` for searchable run history
- `git` for commit/dirty metadata

## Setup

Copy the example connection map and edit the values to match saved SQLcl connection names:

```bash
cp config/connections.conf.example config/connections.conf
```

Example `config/connections.conf`:

```text
admin=admin
dev=my_app_dev
test=my_app_test
prod=my_app_prod
```

You can point at another config file with `SQL_RUNNER_CONFIG=/path/to/connections.conf`.

## Usage

```bash
bin/run-sql.sh --env dev --script examples/verify-connection.sql
```

Use debug mode when you want SQLcl output mirrored to the terminal:

```bash
bin/run-sql.sh --env dev --script examples/verify-connection.sql --log-level debug
```

Production execution is guarded:

```bash
ALLOW_PROD_SQL=yes bin/run-sql.sh --env prod --script deploy/create/00_full.sql
```

## Script Intent

Put an intent block near the top of SQL scripts:

```sql
-- INTENT:
-- Purpose: Add customer preference storage.
-- Approach: Create CUSTOMER_PREFS rather than extending CUSTOMER.
-- Reason: Preferences evolve independently.
-- Expected objects:
--   CUSTOMER_PREFS
--   CUSTOMER_PREFS_PK
-- Risk: Low
-- Prior history checked: None found.
-- END INTENT
```

## History

Initialize or rebuild the SQLite index:

```bash
bin/db-history-init.sh --rebuild
```

Query recent runs:

```bash
bin/db-history-recent.sh
bin/db-history-failures.sh
bin/db-history-similar.sh "package compile failure"
bin/db-history-show.sh <run_id>
```

The SQLite file is a query surface only. The source of truth is the log tree under `logs/`.
