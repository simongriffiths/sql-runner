# sql-runner

Small, auditable SQLcl runner for Oracle Database projects.

`sql-runner` runs project SQL scripts through saved SQLcl connections, writes structured logs under `logs/<env>/runs`, extracts an `INTENT` block from each script, and indexes run history into SQLite when `sqlite3` is available.

The log files are the source of truth. The SQLite database is only a rebuildable query surface.

## Requirements

- Bash
- Oracle SQLcl available as `sql` on `PATH`
- `sqlite3` for searchable run history
- `git` for commit and dirty-worktree metadata
- `shellcheck` for optional linting

## Quick Start

Create or confirm a saved SQLcl connection:

```bash
sql /nolog
conn -save my_user/my_password@example_high -name my_app_dev
exit
```

Copy the example connection map and edit it:

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

Run the smoke test:

```bash
bin/run-sql.sh --env dev --script examples/verify-connection.sql
```

Use debug mode when you want SQLcl output mirrored to the terminal:

```bash
bin/run-sql.sh --env dev --script examples/verify-connection.sql --log-level debug
```

Review recent history:

```bash
bin/db-history-recent.sh dev 5
```

## Configuration

By default, `bin/run-sql.sh` reads:

```text
config/connections.conf
```

Each non-comment line maps a logical environment to a saved SQLcl connection:

```text
dev=my_saved_sqlcl_connection
```

Use a different config file with:

```bash
SQL_RUNNER_CONFIG=/path/to/connections.conf bin/run-sql.sh --env dev --script examples/verify-connection.sql
```

`config/connections.conf` is ignored by git. Publish only `config/connections.conf.example`.

## Running SQL

```bash
bin/run-sql.sh --env <name> --script <file.sql> [--log-level normal|debug]
```

Production execution is guarded:

```bash
ALLOW_PROD_SQL=yes bin/run-sql.sh --env prod --script deploy/create/00_full.sql
```

The runner configures SQLcl with:

- `whenever oserror exit failure rollback`
- `whenever sqlerror exit sql.sqlcode rollback`
- `set serveroutput on size unlimited`
- `set define off`
- `set sqlblanklines on`

After the script runs, it queries `USER_ERRORS` so compile errors are captured in the same log.

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

The block is copied into the run log and SQLite history record.

## Logs

Every run writes a structured log:

```text
logs/<env>/runs/<run_id>.log
```

The log contains:

- `[INFO]`: run id, environment, connection, script path, script hash, git commit, dirty-worktree flag, timestamp
- `[INTENT]`: extracted intent block
- `[ACTION]`: SQLcl output
- `[OUTCOME]`: success/failure and SQLcl exit code

Do not commit `logs/`.

## History Commands

Initialize or rebuild the SQLite index:

```bash
bin/db-history-init.sh --schema-only
bin/db-history-init.sh --rebuild
```

Query recent runs:

```bash
bin/db-history-recent.sh [env] [limit]
```

Find failures:

```bash
bin/db-history-failures.sh [term]
```

Search by description using FTS5 when available:

```bash
bin/db-history-similar.sh "package compile failure"
```

Search by script, path, intent, or summary:

```bash
bin/db-history-script.sh package_name [limit]
```

Search by git commit prefix:

```bash
bin/db-history-commit.sh abc1234 [limit]
```

Show a full run record:

```bash
bin/db-history-show.sh <run_id-or-prefix>
```

## Testing

Offline tests do not require Oracle Database:

```bash
make test
```

This runs shell syntax checks, ShellCheck when installed, SQLite schema creation, fixture log rebuild, and basic runner validation paths.

Live smoke test:

```bash
bin/run-sql.sh --env dev --script examples/verify-connection.sql --log-level debug
```

## Repository Hygiene

Ignored local/runtime files:

- `.codex/`
- `logs/`
- `config/connections.conf`
- `.DS_Store`

Before publishing, confirm no generated logs, wallets, credentials, or local connection maps are staged.
