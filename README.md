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

## Passwords

`road-secrets` generates, stores and applies passwords for ROAD development and test environments. Nobody needs to choose or remember one. It keeps each password in the macOS login keychain and keeps the copies up to date: the database user's SQLcl saved connections, or a road-kit app's `config/local.env`. It refuses anything for production. The full design is in `spec/road-secrets-spec-v1.md`.

It is a per-user tool for macOS, installed once per Mac. It is not copied into projects.

```bash
bin/install-road-secrets.sh
```

This builds the Swift package in `tools/road-secrets`, installs the binary at `~/.local/bin/road-secrets` and checks the login keychain. It needs Swift (`xcode-select --install`) and a road-atlas checkout at `~/Projects/road-atlas`, or wherever `ROAD_ATLAS` points.

Every rebuild gives the binary a new identity. Afterwards, the first read of each Keychain item shows an "Always Allow" prompt on the Mac's screen. Click it once per item, and do not rebuild just before leaving an unattended run.

Keys look like `road/<app>/<env>/<db|principal>/<NAME>`:

```text
road/road-kit/dev/principal/ADMIN    a road-kit scaffold login
road/roadkitdb/dev/db/ADMIN          ADMIN of a database that serves no production
road/livehub/dev/db/LIVEHUB_DEPLOY   a database user, with every saved connection that logs in as it
```

| Command | What it does |
|---|---|
| `road-secrets list [prefix] [--all]` | Lists keys. Never shows passwords. |
| `road-secrets set <key> [options]` | Generates a new password and applies it everywhere |
| `road-secrets sync <key>` | Pushes the Keychain password into every copy |
| `road-secrets get <key>` | Prints the password, for scripts |
| `road-secrets copy <key>` | Puts the password on the clipboard |
| `road-secrets check <key>` | Proves the stored password works |
| `road-secrets delete <key> [--yes]` | Removes the entry. Changes nothing else. |

The first `set` for a database user needs `--connection <saved connection> --wallet <wallet zip or directory> --tns <TNS name>`. To adopt the user, either type its current password at the terminal, or use `--via-admin` once the database's ADMIN entry exists. `set` changes the password once and re-saves every saved connection that logs in as that user, including proxy logins. When there is more than one, it asks first, unless you pass `--yes`. Run it in a desktop session on the Mac, not over SSH.

### Approval gate for ADMIN work

Add these rules to the `ask` list in `~/.claude/settings.json`. That file applies to every project, and the Code tab of the Claude desktop app reads it too. Claude Code then asks before running a script as ADMIN, or before reading an ADMIN password.

```json
{
  "permissions": {
    "ask": [
      "Bash(bin/run-sql.sh --env admin *)",
      "Bash(./bin/run-sql.sh --env admin *)",
      "Bash(road-secrets get *ADMIN)",
      "Bash(road-secrets copy *ADMIN)",
      "Bash(*/road-secrets get *ADMIN)",
      "Bash(*/road-secrets copy *ADMIN)"
    ]
  }
}
```

These rules are a prompt, not a security boundary. The same program can be called in forms they do not match.

## Testing

Offline tests do not require Oracle Database:

```bash
make test
```

This runs shell syntax checks, ShellCheck when installed, SQLite schema creation, fixture log rebuild, and basic runner validation paths.

road-secrets unit tests, which need Swift but no database or Keychain:

```bash
make road-secrets-test
```

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
