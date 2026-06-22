# Publishing Checklist

- Confirm the repository contains no real logs, wallets, passwords, or generated `.codex` history databases.
- Keep `config/connections.conf` ignored; publish only `config/connections.conf.example`.
- Choose and add a licence before public release.
- Run `make test`.
- Run a live smoke test against a disposable SQLcl saved connection.
- Confirm `git status --ignored --short` shows only expected ignored runtime files.
