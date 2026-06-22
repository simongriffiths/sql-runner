# Contributing

Keep changes small and testable.

Before opening a pull request, run:

```bash
make test
```

Live database tests should use disposable schemas or read-only smoke scripts. Do not include real logs, credentials, wallets, or local connection files in commits.
