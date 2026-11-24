.PHONY: test lint smoke-history road-secrets-test

test: lint smoke-history

lint:
	bash -n bin/*.sh test/*.sh skills/sql-runner/scripts/*.sh
	@if command -v shellcheck >/dev/null 2>&1; then \
		shellcheck bin/*.sh test/*.sh skills/sql-runner/scripts/*.sh; \
	else \
		echo "[WARN] shellcheck not found; skipped shell lint"; \
	fi

smoke-history:
	test/run-offline-tests.sh

# The Command Line Tools toolchain sometimes fails a build with "plugin for module TestingMacros not
# found". A second build succeeds, so build once more before running the tests.
road-secrets-test:
	cd tools/road-secrets && (swift build --build-tests >/dev/null 2>&1 || swift build --build-tests) && swift test --skip-build
