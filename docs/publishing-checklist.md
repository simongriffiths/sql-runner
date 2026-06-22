# Publishing Checklist

- Confirm the repository contains no real logs, wallets, passwords, or generated `.codex` history databases.
- Keep `config/connections.conf` ignored; publish only `config/connections.conf.example`.
- Run `bash -n bin/*.sh`.
- Run `bin/db-history-init.sh --schema-only`.
- Run a live smoke test against a disposable SQLcl saved connection.
- Decide whether to add convenience helpers for script and commit searches before public release.
