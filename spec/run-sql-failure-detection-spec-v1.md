# run-sql.sh Failure Detection Specification

**Version:** 1.0 (draft)
**Date:** 2026-11-22
**Repository:** `sql-runner`
**Changes:** `bin/run-sql.sh`, its offline tests, the sql-runner skill
**Status:** Ready for build, subject to the spikes in Section 7

---

## 1. Purpose

`run-sql.sh` can report a run as a success when it failed. There are two separate causes.

1. **Compile errors do not stop a run.** When Oracle compiles a PL/SQL unit with errors, the database driver returns a warning. `whenever sqlerror` does not react to warnings. The object is created in an invalid state, the script carries on, and SQLcl exits with 0. road-kit's own `deploy/create/70_package_bodies.sql` already warns about this in its INTENT block.
2. **Some SQL errors exit with status 0.** Scripts use `whenever sqlerror exit sql.sqlcode`. A Unix exit status holds only one byte. The shell therefore sees the error code modulo 256. Any Oracle error code that is a multiple of 256 arrives as 0. Examples are ORA-01536 (space quota exceeded, 6 × 256) and ORA-20480 (80 × 256). `run-sql.sh` then records a success.

Both matter most for unattended work. Claude Code relies on the exit code and the console summary. A false success lets it carry on as if a deploy had worked.

This change makes `run-sql.sh` detect both cases from the log it already writes. Scripts do not change. The history database schema does not change.

---

## 2. Background: how others solve this

These findings shaped the design.

- **There is no built-in SQL*Plus or SQLcl switch for compile errors.** The problem has been reported since at least 1997.
- **The classic SQL*Plus fix** puts a PL/SQL block after each `CREATE`. The block counts the object's rows in `USER_ERRORS` and raises an error if there are any. It works. It also adds boilerplate to every file. It is the fallback in Section 6.
- **Migration tools fail at the statement.** Flyway documents that a failed Oracle compile reaches it as a driver warning with error code 17110. Its recommended fix turns that warning into an error. This design does the same thing by reading SQLcl's output for each compile.
- **Exit codes above 255 are a documented Unix limit.** The usual advice is to return a fixed failure code and keep the real error elsewhere. sql-runner already records the full Oracle error in the log and the run summary.

---

## 3. Design

### 3.1 Completion marker

Add one line to the here-document that drives SQLcl, straight after the script:

```
@${SCRIPT_PATH}
prompt [INFO] SCRIPT_COMPLETE
prompt [INFO] USER_ERRORS_CHECK
...
```

If `whenever sqlerror` or `whenever oserror` stops the session, SQLcl never reaches the `prompt`. So after SQLcl exits:

- If `[INFO] SCRIPT_COMPLETE` is **absent** from the log, the run failed. This holds whatever the exit code was.
- If SQLcl's exit code was 0, set it to 1.
- Append `[ERROR] SCRIPT_INCOMPLETE: the script stopped before its last statement` to the log, before `[OUTCOME]`.

This catches the modulo-256 case with no need to search the log for `ORA-` text. That matters because a script may print text containing `ORA-` on purpose, for example from `dbms_output`.

It has two side effects, both correct:

- A script that ends inside an unterminated PL/SQL block (a missing `/`) swallows the `prompt` line. The run then fails. Today it may pass.
- A script that calls `EXIT` or `QUIT` itself also fails. Section 3.5 adds a rule against that.

### 3.2 Compile failures

After SQLcl exits, scan the part of the log between `[ACTION]` and `[INFO] SCRIPT_COMPLETE`. If the marker is absent, scan to the end of the log. Find each **compile-failure block**: the lines SQLcl prints for one object that compiled with errors.

The exact text is confirmed by spike S1. The expected shape, from SQLcl output seen elsewhere, is:

```
Package Body HEALTH_API compiled

LINE/COL  ERROR
--------- -------------------------------------------------------------
3/5       PLS-00201: identifier 'NO_SUCH_THING' must be declared
Errors: check compiler log
```

For each block, extract:

- the object type and name, from the `... compiled` line before the error lines
- the error lines, meaning every line between the `LINE/COL` heading rule and `Errors: check compiler log`

A block counts as a **failure** only if at least one error line contains `PLS-` or `ORA-`. A block with only `PLW-` lines is a compiler warning. Warnings do not fail a run.

If any failure blocks exist:

- Set the status to FAILURE.
- If SQLcl's exit code was 0, set it to 1.
- Append this section to the log, before `[OUTCOME]`:

  ```
  [COMPILE_FAILURES]
  PACKAGE BODY HEALTH_API
    3/5 PLS-00201: identifier 'NO_SUCH_THING' must be declared
  PACKAGE BODY SESSION_API
    12/7 PLS-00103: Encountered the symbol "END"
  [END COMPILE_FAILURES]
  [ERROR] COMPILE_FAILURES=2
  ```

  Write object types in uppercase. Keep up to 5 error lines per object and note `(n more)` if there are others.

Do the scan in `awk`, as `run-sql.sh` already does for the INTENT block. Put it in a function in a new `bin/run-sql-common.sh`. The offline tests can then call it directly.

### 3.3 Where the failing statement was

When the completion marker is absent, find SQLcl's report for the error that stopped the run. Spike S2 confirms its format. SQLcl normally prints a header naming the line, and for a script the file. If S2 confirms that, extract the file and line, and append to the log before `[OUTCOME]`:

```
[ERROR] FAILED_AT=db/tables/road_roles.create.sql:14
```

If S2 shows that SQLcl does not name the file, skip this section and record that in the journal.

### 3.4 Run summary

`run-sql.sh` builds a one-line summary for the history database. Extend it:

- For compile failures, add `Compile failures: HEALTH_API (PACKAGE BODY), SESSION_API (PACKAGE BODY).` The existing `KEY_ERRORS` search only matches lines that start with `ORA-`, `PLS-` or `SP2-`. It misses compile errors. SQLcl indents those under `LINE/COL`.
- For an incomplete script, add `Stopped early` and the `FAILED_AT` location if known.

The summary stays one line. The full detail is in the log.

### 3.5 Console output

Add these lines to the existing console summary. Claude Code then sees them without opening the log:

```
[ERROR] FAILURE
[ERROR] COMPILE_FAILURES=2: HEALTH_API (PACKAGE BODY), SESSION_API (PACKAGE BODY)
[INFO] LOG_FILE=...
```

or:

```
[ERROR] FAILURE
[ERROR] SCRIPT_INCOMPLETE at db/tables/road_roles.create.sql:14
```

### 3.6 What does not change

- The `whenever` settings that `run-sql.sh` injects, and those in scripts. Scripts may keep `exit sql.sqlcode`.
- The `USER_ERRORS_CHECK` listing. It stays in the log for diagnosis. It still covers the whole schema. It no longer decides the status.
- The history database schema. `status` stays `SUCCESS` or `FAILURE`.
- Behaviour when SQLcl's exit code is already non-zero. The code is passed through unchanged, as now.

---

## 4. Exit code rules after this change

| Condition | Exit code |
|---|---|
| Script complete, no compile failures, SQLcl exit 0 | 0 |
| SQLcl exit non-zero | SQLcl's code, unchanged (may be the Oracle code modulo 256) |
| SQLcl exit 0, completion marker absent | 1 |
| SQLcl exit 0, compile failures found | 1 |
| Existing argument, config and precondition errors | Unchanged (2 or 127) |

This amends Section 9 of road-kit's `spec/run-sql-sh-spec-v2.md`. That spec says the runner must return SQLcl's exit code unchanged. The amendment allows exactly two overrides, both from 0 to 1. Update that spec, or record the amendment in `../road-atlas`, as part of this change.

---

## 5. Skill changes

In `skills/sql-runner/SKILL.md`:

- Add a rule: scripts must not call `EXIT` or `QUIT`. `run-sql.sh` ends the session itself.
- Change the post-run review step. A run is failed if the console or log shows `COMPILE_FAILURES` or `SCRIPT_INCOMPLETE`. Read the `[COMPILE_FAILURES]` section first, then `FAILED_AT`. Treat the `USER_ERRORS` listing as background only, because it covers the whole schema.

---

## 6. Fallback: per-object markers

Build this only if spike S1 shows that SQLcl does not name the object before its errors, or does not print the errors at all.

- Add one line at the top of each object file: `prompt [OBJECT] <TYPE> <NAME>`, for example `prompt [OBJECT] PACKAGE BODY HEALTH_API`.
- After the run, collect the names from those lines. Query `USER_ERRORS` for exactly those objects in the same SQLcl session, before `exit success`, and print the rows under a `[COMPILE_FAILURES]` heading in the same format as Section 3.2.
- Ship a script that adds the line to existing object files in a consuming repository, and a check that reports object files without it.

This needs a change to every object file. That is why it is the fallback.

---

## 7. Spikes

Run these first, against a dev database, with the SQLcl version on the Mac mini. Save the raw log of each case to `test/fixtures/` with any secrets removed, and record the findings in `docs/journal/`. If S1 shows the expected shape is wrong, stop and report before building Section 3.2.

- **S1. Compile output.** Run scripts through the current `run-sql.sh` that create:
  1. a package body with one error
  2. a package body with three errors
  3. a procedure that compiles with only a `PLW-` warning, with `plsql_warnings` set to `'ENABLE:ALL'` for the session
  4. a trigger and a view with errors (views fail differently and may raise a hard error)
  5. a package spec and body in one file, where only the body fails

  Record exactly what SQLcl prints in each case, with `set echo off` and `set feedback on`. Confirm whether the object name and type appear on the `compiled` line, and whether error lines appear without `show errors`.

- **S2. Stopping error.** Run a script with a table create that fails (for example, a duplicate name), called through an `@` include. Record SQLcl's error report and whether it names the file and line.

- **S3. Modulo-256 exit.** Run a script containing `exec raise_application_error(-20480, 'test')` through the current `run-sql.sh`. Confirm that it is recorded as SUCCESS today. After the change, confirm that it is recorded as FAILURE with `SCRIPT_INCOMPLETE`.

- **S4. Impact on road-kit.** With the new runner, run road-kit's `deploy/create/00_full.sql` on a dev database. List every compile failure it now reports that the current runner passes. Fix each one, or record it in `docs/journal/` as a known issue for road-kit. Do not release until this list is understood.

---

## 8. Tests

Extend `test/run-offline-tests.sh`. The runner already reads `SQLCL_BIN`. The tests therefore use a fake SQLcl: a small script that reads standard input, prints a chosen fixture and exits with a chosen code. Build the fixtures from the spike logs.

| Case | Fake output | Fake exit | Expected status | Expected exit |
|---|---|---|---|---|
| Clean run | Fixture with marker, no failures | 0 | SUCCESS | 0 |
| One compile failure | S1 case 1 | 0 | FAILURE | 1 |
| Three compile failures | S1 case 2 | 0 | FAILURE | 1 |
| Warning only | S1 case 3 | 0 | SUCCESS | 0 |
| Script stopped, exit truncated to 0 | S3 output, no marker | 0 | FAILURE | 1 |
| Script stopped, normal exit code | S2 output, no marker | The code recorded in S2 | FAILURE | The same code |
| Missing `/` swallows the marker | Output with no marker | 0 | FAILURE | 1 |

For each case, also check:

- the `[COMPILE_FAILURES]` section and the `COMPILE_FAILURES=<n>` line
- `FAILED_AT` when S2 confirmed the format
- the summary stored in the history database
- the console lines from Section 3.5

`make test` and `make lint` must pass.

---

## 9. Rollout

1. Merge to sql-runner.
2. Reinstall sql-runner into road-kit, road-cal, road-blogger and quorate with `install-sql-runner.sh`. Run each repository's full deploy on dev and deal with any compile failures that now appear.
3. Record the change in `../road-atlas`, naming the four consumers. Note that `aida` still runs a stale fork (ledger `L-02`) and does not get this fix.
4. Update the run-history pane spec to read `[COMPILE_FAILURES]` (done in its own branch).

---

## 10. Build order

1. Spikes S1 to S3, with fixtures
2. Fake SQLcl and the new offline test cases, all failing
3. Completion marker (Section 3.1)
4. Compile-failure scan (Section 3.2)
5. `FAILED_AT` (Section 3.3), if S2 allows
6. Summary and console output (Sections 3.4 and 3.5)
7. Skill changes (Section 5)
8. Spike S4 on road-kit
9. Rollout (Section 9)
