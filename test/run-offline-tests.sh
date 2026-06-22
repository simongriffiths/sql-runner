#!/usr/bin/env bash
set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/sql-runner-test.XXXXXX")"
trap 'rm -rf "${WORK_DIR}"' EXIT

DB_HISTORY_FILE="${WORK_DIR}/db-history.sqlite" \
  "${PROJECT_ROOT}/bin/db-history-init.sh" --schema-only

DB_HISTORY_FILE="${WORK_DIR}/db-history.sqlite" \
  sqlite3 "${WORK_DIR}/db-history.sqlite" 'select count(*) from runs;' >/dev/null

FIXTURE_ROOT="${WORK_DIR}/fixture-repo"
mkdir -p "${FIXTURE_ROOT}/logs/dev/runs"
cp -R "${PROJECT_ROOT}/bin" "${FIXTURE_ROOT}/bin"
cp "${PROJECT_ROOT}/test/fixtures/logs/dev/runs/20260101_010203_sample_success_123.log" \
  "${FIXTURE_ROOT}/logs/dev/runs/"

(
  cd "${FIXTURE_ROOT}"
  DB_HISTORY_FILE="${WORK_DIR}/fixture-history.sqlite" bin/db-history-init.sh --rebuild >/dev/null
  COUNT="$(DB_HISTORY_FILE="${WORK_DIR}/fixture-history.sqlite" sqlite3 "${WORK_DIR}/fixture-history.sqlite" 'select count(*) from runs;')"
  [[ "${COUNT}" = "1" ]]

  STATUS="$(DB_HISTORY_FILE="${WORK_DIR}/fixture-history.sqlite" sqlite3 "${WORK_DIR}/fixture-history.sqlite" "select status from runs where run_id = '20260101_010203_sample_success_123';")"
  [[ "${STATUS}" = "SUCCESS" ]]

  DB_HISTORY_FILE="${WORK_DIR}/fixture-history.sqlite" bin/db-history-script.sh sample >/dev/null
  DB_HISTORY_FILE="${WORK_DIR}/fixture-history.sqlite" bin/db-history-commit.sh abc1234 >/dev/null
  DB_HISTORY_FILE="${WORK_DIR}/fixture-history.sqlite" bin/db-history-similar.sh "fixture package" >/dev/null
)

CONFIG_FILE="${WORK_DIR}/connections.conf"
printf 'dev = saved_dev\n' >"${CONFIG_FILE}"

set +e
SQL_RUNNER_CONFIG="${WORK_DIR}/missing.conf" \
  SQLCL_BIN=/bin/false \
  "${PROJECT_ROOT}/bin/run-sql.sh" --env dev --script examples/verify-connection.sql >/tmp/sql-runner-missing-config.out 2>&1
MISSING_CONFIG_EXIT=$?
set -e
[[ "${MISSING_CONFIG_EXIT}" = "2" ]]
grep -q 'SQL runner config not found' /tmp/sql-runner-missing-config.out

set +e
SQL_RUNNER_CONFIG="${CONFIG_FILE}" \
  SQLCL_BIN=/bin/false \
  "${PROJECT_ROOT}/bin/run-sql.sh" --env missing --script examples/verify-connection.sql >/tmp/sql-runner-missing-env.out 2>&1
MISSING_ENV_EXIT=$?
set -e
[[ "${MISSING_ENV_EXIT}" = "2" ]]
grep -q 'Unknown environment: missing' /tmp/sql-runner-missing-env.out

echo "[INFO] Offline tests passed"
