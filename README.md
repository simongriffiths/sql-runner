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

Every everyday command takes one argument: the key, exactly as `list` prints it. The commands work from any folder.

| Command | What it does |
|---|---|
| `road-secrets list [prefix] [--all]` | Lists keys. Never shows passwords. |
| `road-secrets add --app <app> --env <env> --kind <db\|principal> --name <NAME> [details]` | Creates a new entry and sets its first password |
| `road-secrets set <key>` | Generates a new password and applies it everywhere |
| `road-secrets sync <key>` | Pushes the Keychain password into every copy |
| `road-secrets get <key>` | Prints the password, for scripts |
| `road-secrets copy <key>` | Puts the password on the clipboard |
| `road-secrets check <key>` | Proves the stored password works |
| `road-secrets delete <key> [--yes]` | Removes the entry. Changes nothing else. |

`add` never asks a question, and it prints the new key when it succeeds. `--kind` is required.

To add a database user, give one saved connection that logs in as it, the wallet and the TNS name. Then do one of these:

- Pipe in the user's current password. It is read from standard input with no prompt and no echo.
- Use `--via-admin`, once the database's ADMIN entry exists.

```bash
pbpaste | road-secrets add --app roadkitdb --env dev --kind db --name ADMIN \
  --connection roadkit_admin --wallet ~/wallets/roadkitdb.zip --tns roadkitdb_medium
```

```bash
road-secrets add --app livehub --env dev --kind db --name LIVEHUB_DEPLOY --via-admin --yes \
  --connection livehub_av_acc --wallet ~/wallets/roadkitdb.zip --tns roadkitdb_medium
```

The password changes once, and every saved connection that logs in as that user is re-saved, proxy logins included. When there is more than one, pass `--yes`. Later, `road-secrets set <key>` rotates it, with everything else taken from the entry. `set` asks before re-saving several connections when you are at a terminal. Otherwise it needs `--yes`. Run it in a desktop session on the Mac, not over SSH.

To add a road-kit principal, use `road-secrets add --app road-kit --env dev --kind principal --name ADMIN`. The app's folder is `$ROAD_PROJECTS/<app>`, or `~/Projects/<app>` if `ROAD_PROJECTS` is unset. Pass `--project <path>` if it is elsewhere. The folder is stored, so later commands find it from anywhere.

`set`, `sync` and `check` on a key that does not exist exit 3 and show the `add` command to use. `add` on a key that exists exits 2 and points to `set`.

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
