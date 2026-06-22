# Security Policy

Do not commit wallets, passwords, private connection files, generated logs, or `.codex` history databases.

`config/connections.conf` is intentionally ignored because saved SQLcl connection names can reveal environment details. Publish only `config/connections.conf.example`.

If you discover a security issue in this repository, report it privately to the repository owner rather than opening a public issue with sensitive details.
