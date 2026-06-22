.PHONY: test lint smoke-history

test: lint smoke-history

lint:
	bash -n bin/*.sh test/*.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck bin/*.sh test/*.sh; \
	else \
		echo "[WARN] shellcheck not found; skipped shell lint"; \
	fi

smoke-history:
	test/run-offline-tests.sh
