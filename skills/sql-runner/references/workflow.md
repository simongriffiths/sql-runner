# sql-runner Workflow Reference

## Installation

Install into a target project from a repo checkout:

```bash
skills/sql-runner/scripts/install-sql-runner.sh --target /path/to/project
```

Install from GitHub when the full source checkout is not present:

```bash
skills/sql-runner/scripts/install-sql-runner.sh --target /path/to/project --source git
```

The installer copies:

- `bin/`
- `config/connections.conf.example`
- `examples/verify-connection.sql`
- `docs/publishing-checklist.md`

It does not overwrite `config/connections.conf`.

## Configuration

`config/connections.conf` maps logical environments to saved SQLcl connections:

```text
dev=my_app_dev
test=my_app_test
prod=my_app_prod
```

Use an alternate config with:

```bash
SQL_RUNNER_CONFIG=/path/to/connections.conf bin/run-sql.sh --env dev --script examples/verify-connection.sql
```

## Production Safety

Production runs require both:

- explicit user confirmation
- `ALLOW_PROD_SQL=yes`

Example:

```bash
ALLOW_PROD_SQL=yes bin/run-sql.sh --env prod --script deploy/create/00_full.sql
```

Do not set `ALLOW_PROD_SQL=yes` by default in scripts or shell profiles.

## Post-Run Review

After every run:

1. Confirm `STATUS=SUCCESS` or inspect failure details.
2. Open the log file named in console output if details are needed.
3. Check the `USER_ERRORS` section for invalid PL/SQL objects.
4. Use `bin/db-history-show.sh <run_id>` to confirm the indexed record.
5. If a run failed, search it before retrying:
   - `bin/db-history-failures.sh <term>`
   - `bin/db-history-show.sh <run_id>`

## Log And History Model

Logs under `logs/<env>/runs/` are authoritative.

`.codex/db-history.sqlite` is a rebuildable query surface:

```bash
bin/db-history-init.sh --rebuild
```

Do not commit logs, `.codex/`, wallets, passwords, or `config/connections.conf`.
