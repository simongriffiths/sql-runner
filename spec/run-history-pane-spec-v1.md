# Run-History Pane Specification

**Version:** 1.1 (draft)
**Date:** 2026-11-22
**Repository:** `sql-runner`
**Status:** Ready for build, subject to the spikes in Section 11
**Depends on:** `spec/run-sql-failure-detection-spec-v1.md` (branch `spec/run-sql-failure-detection`). Build that first.

---

## 1. Purpose

The run-history pane is a Claude Code mod that shows sql-runner's run history inside Claude Code. A mod is a plugin made of JavaScript or TypeScript event handlers that run inside Claude Code and can draw interface elements.

sql-runner already records every run in two places. Each run writes a log file under `logs/<env>/runs/`, and each run is indexed in a SQLite database at `.codex/db-history.sqlite`. Today the only way to see either is to run a history script or open a log by hand. The pane makes the history visible at a glance, beside the conversation, while Claude works.

The pane is read-only. It never connects to a database, never needs a password and never runs SQL.

---

## 2. Scope

### 2.1 In scope

- A pane listing recent runs for the current project, with filters for environment and status
- A detail view for one run, showing its intent, key errors, compile failures and where a stopped script failed, with the full log on request
- Automatic refresh when Claude runs `run-sql.sh`
- The Code tab of the Claude desktop app and the Claude Code CLI, on macOS

### 2.2 Out of scope

- Running, re-running or editing SQL from the pane
- Any database connection, including the Oracle explorer pane. That will be a later pane in the same plugin.
- Full-text search across runs. `bin/db-history-similar.sh` already provides it. It may be added to the pane in a later version.
- Changes to `bin/run-sql.sh` or the history database schema
- The VS Code extension. The pane may work there. It is not tested there.

---

## 3. Background and constraints

1. **The log files are the source of truth.** `AGENTS.md` says the SQLite database is a rebuildable query surface. The pane reads the database for the list and reads the log file for detail. If the two disagree, the log wins.
2. **The history database belongs to each project.** It lives at `.codex/db-history.sqlite` under the project root. `DB_HISTORY_FILE` overrides that path. The pane must honour the same override.
3. **The mod runs with the user's permissions and is not sandboxed.** It must stay read-only. It may call only `$.fs.read`, `$.fs.stat`, `$.fs.exists`, `$.fs.ancestors`, `$.env.get`, `$.process.run` (for `sqlite3` only), `$.store`, `$.ui.*`, `$.clock.*`, `$.command.register`, `$.session.cwd` and `$.prompt.submit`. `claude plugin validate` lists every call a mod makes. The build must check that list against this one.
4. **One copy per user.** The mod is installed once, as a plugin, and reads whichever project the session is in. It is not copied into each repository the way the sql-runner skill is.
5. **Compatibility.** Mods need Claude Code v2.1.287 or later in the terminal. In the desktop app they work from v2.1.286. Avoid the `Box` spacing step names and the `Text` typography props. They need v2.1.299. Use numeric spacing.

---

## 4. Layout

| Item | Location |
|---|---|
| Marketplace manifest | `sql-runner/.claude-plugin/marketplace.json` |
| Plugin | `sql-runner/plugins/sql-runner-panes/` |
| Plugin manifest | `plugins/sql-runner-panes/.claude-plugin/plugin.json` |
| Hooks list | `plugins/sql-runner-panes/hooks/hooks.json` |
| Hooks module | `plugins/sql-runner-panes/hooks/register.ts` |
| Pure logic (parsing, formatting) | `plugins/sql-runner-panes/hooks/lib/*.ts` |
| Tests | `plugins/sql-runner-panes/hooks/**/*.test.ts` |
| This spec | `sql-runner/spec/run-history-pane-spec-v1.md` |

The plugin is named `sql-runner-panes`, because the Oracle explorer will join it later. The user installs it with:

```
/plugin marketplace add simongriffiths/sql-runner
/plugin install sql-runner-panes@sql-runner
```

Keep parsing and formatting in `lib/` as plain functions with no `$` calls. That makes them testable without a session.

---

## 5. Finding the history

When the pane opens or refreshes:

1. Find the project root. Walk up from `$.session.cwd()` with `$.fs.ancestors` to the nearest directory containing `bin/run-sql.sh`.
2. Find the database. Use `DB_HISTORY_FILE` if `$.env.get('DB_HISTORY_FILE')` returns a value. Otherwise use `<project root>/.codex/db-history.sqlite`.
3. If there is no project root, show "This project does not use sql-runner." If the database does not exist, show "No runs recorded yet." Neither is an error.


---

## 6. Reading the database

- Run `sqlite3` with `$.process.run`, passing an argument list: `['sqlite3', '-readonly', '-json', <database path>, <query>]`. `$.process.run` uses no shell. There is therefore no quoting to get wrong.
- Build each query from fixed text. Filter values come only from the pane's own `Select` controls, which offer a fixed set of values. Even so, check each value against `^[a-z0-9_-]+$` before putting it in a query.
- Give each call a 5-second timeout. On failure, show the error in the pane and keep the last good list.

The list query:

```sql
select run_id, run_ts, env, connection, script, status, sqlcl_exit,
       intent, log_file, git_commit, git_dirty
  from runs
 [where env = '<env>'] [and status = 'FAILURE']
 order by run_ts desc
 limit 25;
```

The environment filter options come from:

```sql
select distinct env from runs order by env;
```

`run_ts` is the local time the run started, in the form `YYYYMMDD_HHMMSS`. Show it as `22 Nov 00:12`. Show the year as well when it is not the current year.

---

## 7. Reading a log

Logs are small text files written by `run-sql.sh`. Read them with `$.fs.read`. A log over 4 MiB cannot be read whole by a mod. In that case, show "Log too large to display" and offer the path.

A log has these sections, in this order:

```
[INFO] START
[INFO] RUN_ID=...           (and other [INFO] header lines)
[INTENT]
...intent text...
[END INTENT]
[ACTION]
...SQLcl output...
[INFO] SCRIPT_COMPLETE      (absent if the script stopped early)
[INFO] USER_ERRORS_CHECK
...rows from USER_ERRORS, or "no rows selected"...
[COMPILE_FAILURES]          (only if any)
...one line per object, then its error lines...
[END COMPILE_FAILURES]
[ERROR] COMPILE_FAILURES=<n>
[ERROR] SCRIPT_INCOMPLETE: ...   (only if the script stopped early)
[ERROR] FAILED_AT=<file>:<line>  (only if known)
[OUTCOME]
STATUS=SUCCESS|FAILURE
SQLCL_EXIT=<n>
[INFO] SQLCL_EXIT=<n>
[INFO] END
```

The parser in `lib/log.ts` returns:

| Field | How it is found |
|---|---|
| `intent` | The lines between `[INTENT]` and `[END INTENT]` |
| `purpose` | The text after `Purpose:` in the intent, or the first intent line if there is no `Purpose:` |
| `keyErrors` | Lines in the action section starting with `ORA-`, `PLS-`, `SP2-` or `Unknown connection`. These are the same patterns `run-sql.sh` uses for its summary. Keep the first 10. |
| `compileFailures` | The objects and error lines between `[COMPILE_FAILURES]` and `[END COMPILE_FAILURES]`. Empty if the section is absent. |
| `incomplete`, `failedAt` | `true` when `[ERROR] SCRIPT_INCOMPLETE` is present, and the value of `FAILED_AT` if there is one |
| `userErrors` | The lines after `[INFO] USER_ERRORS_CHECK` and before the next section, with blank lines removed. Empty if the section says `no rows selected` or is absent. |
| `status`, `exitCode` | From `STATUS=` and `SQLCL_EXIT=` in the outcome section |
| `complete` | `true` when `[INFO] END` is present |

The pane shows `compileFailures` as the run's compile errors. These are the objects this run failed to compile, as found by `run-sql.sh`.

`userErrors` is background only. It lists every invalid object in the schema, including ones the run did not touch. The pane shows it collapsed, under the label "All compile errors in schema after this run". It must never say the run caused them.

**Logs from before the failure-detection change** have no `[COMPILE_FAILURES]` section and no `SCRIPT_COMPLETE` marker. For those logs, show `userErrors` under the same schema-wide label and show no compile-failure section. Do not try to work out which errors belong to the run.

---

## 8. The pane

### 8.1 Opening

- Register the command `/sql-runs` in `session.start`. Its description is "Show sql-runner run history".
- `/sql-runs` opens the pane with `$.ui.open({ id: 'sql-runs', title: 'SQL runs', focus: true, closeOnEscape: true })` and returns `{}`. Nothing is then printed in the transcript.
- The pane opens only when the user asks. It never opens itself.

### 8.2 List view

From top to bottom:

1. **Controls row:**
   - A `Select` for environment: "All" plus each value from the environment query.
   - A `Select` for status: "All runs" or "Failures only".
   - A `Button` labelled "Refresh".
2. **One row per run,** newest first. Each row is a `Button` whose label reads:

   ```
   ✓ 22 Nov 00:12  dev  70_package_bodies.sql  Deploy package bodies
   ```

   | Part | Content |
   |---|---|
   | Mark | `✓` for success, `✗` for failure, `…` for a log with no `[INFO] END` (still running or interrupted) |
   | Time | From `run_ts`, as in Section 6 |
   | Environment | `env` |
   | Script | The file name only, from `script` |
   | Purpose | From the log, cut to fit `e.props.bodyColumns` |

   Pressing a row opens its detail view.
3. **A footer line** in dim text, such as `25 most recent · road-cal · .codex/db-history.sqlite`.

The `…` mark and the purpose need the log. Read the logs for the visible rows only, and cache each parsed result in memory by `run_id`. A finished log never changes. A cached result for a log with `[INFO] END` never needs reading again.

Remember the two filter choices in `$.store` under the project root's path. Restore them when the pane next opens in that project.

### 8.3 Detail view

From top to bottom:

1. A `Button` labelled "Back".
2. A header block:
   - Status and mark, environment, connection, script path
   - Started (from `run_ts`), exit code, git commit, with "(uncommitted changes)" when `git_dirty` is `true`
3. **Intent:** the intent text in a `Code` element.
4. **Where it stopped:** for an incomplete script, the `FAILED_AT` location if known, or "Stopped before its last statement".
5. **Compile failures:** each object and its error lines, if any, in a `Code` element.
6. **Errors:** the key errors, if any, in a `Code` element.
7. **All compile errors in schema after this run:** the `userErrors` lines, collapsed behind a button labelled "Show schema errors".
8. A row of buttons:
   - **"Show log":** replaces sections 3 to 7 with the whole log in a `Code` element. The tree's text limit is 100,000 characters. If the log is longer, show its last 100,000 characters with a note saying it was cut.
   - **"Copy log path":** copies the absolute log path with `$.ui.copy`.
   - **"Ask Claude":** only on failures. It calls `$.prompt.submit` with this text: `Look at sql-runner run <run_id>. Its log is at <path>. Explain what went wrong and propose a fix. Do not re-run anything until I agree.` It starts a turn only when pressed.

---

## 9. Refreshing

The pane refreshes in three cases. Each case re-runs the list query and calls `$.ui.invalidate('ui.render')`.

1. **After Claude runs `run-sql.sh`.** Add a `tool.call` hook filtered to `{ tool: 'Bash' }`. When `e.command` contains `run-sql.sh`, await `next(e)`, refresh, then return the result unchanged. The hook must never change, delay beyond the refresh, or deny the call. If refreshing throws, swallow the error and return the result.
2. **While the pane is open, every 15 seconds.** Use `$.clock.every`. Check the database file's modification time with `$.fs.stat`, and refresh only if it changed. This covers runs started in a terminal and runs Claude starts in the background. Cancel the timer when the pane closes (`ui.close`) and when the session ends.
3. **When the user presses "Refresh".**

Do not poll while the pane is closed.

---

## 10. Tests

Use `claude plugin test`. Tests live beside the code as `*.test.ts`.

- **Log parser:** fixtures for a successful run, a failed run with an `ORA-` error, a run with `[COMPILE_FAILURES]`, a run with `SCRIPT_INCOMPLETE` and `FAILED_AT`, a log from before the failure-detection change with USER_ERRORS rows, a log with no `[INFO] END`, a log with no intent block, and a log with `Purpose:` on a later intent line. Reuse the fixtures from the failure-detection spikes where possible. Put the fixtures in `plugins/sql-runner-panes/hooks/lib/fixtures/`. Build them from real logs with any secrets removed.
- **Formatting:** time formatting for this year and an earlier year, row labels cut to a given width, and each mark.
- **Query building:** filters produce the expected SQL. Values failing `^[a-z0-9_-]+$` are rejected.
- **Hooks with stubbed calls:** opening the pane with no project root, with no database, and with a stubbed `sqlite3` result. The `tool.call` hook refreshes after a `run-sql.sh` command and passes other commands through untouched.
- **Validation:** `claude plugin validate --strict` passes. Its `calls:` list contains nothing outside Section 3, item 3.

Then run this manual checklist in a real project (road-kit is a good one) and record the results in `docs/journal/`:

1. `/sql-runs` opens the pane in the desktop app's Code tab, and in the CLI.
2. Asking Claude to run a deploy script refreshes the pane when the run ends.
3. A run from a terminal appears within 15 seconds.
4. Filters work and are remembered after a restart.
5. A failed run's detail view shows its key errors, and "Ask Claude" starts a turn with the expected text.
6. A run with a compile failure shows `✗`, and its detail view lists the failing object and its errors.
7. In a repository without sql-runner, the pane shows the "does not use sql-runner" message.

---

## 11. Spikes

Run these first and record each result in `docs/journal/`. If one fails, stop and report before building the affected part.

- **P1. Drawing in the desktop app.** In the Code tab, open a pane holding a `Select`, a `Button` and a `Code` element. Confirm that each draws and responds, and note where the pane appears.
- **P2. `sqlite3` on the Mac mini.** Confirm that the installed `sqlite3` accepts `-readonly` and `-json`, and record the JSON shape it returns for an empty result.
- **P3. The `tool.call` hook.** Confirm that a hook on `{ tool: 'Bash' }` receives the command as `e.command`, and that `await next(e)` returns only after the command finishes. Also record what happens for a command Claude runs in the background.

---

## 12. Build order

1. Spikes P1 to P3
2. Plugin and marketplace skeleton, loaded with `claude --plugin-dir`
3. `lib/` parsing and formatting with tests
4. List view with the database query
5. Detail view with log reading
6. Refresh hooks and timer
7. `claude plugin validate --strict` and the test suite
8. README section on installing the plugin
9. Manual checklist
10. A note in `../road-atlas`, as `AGENTS.md` requires, saying the plugin exists and which repositories it serves
