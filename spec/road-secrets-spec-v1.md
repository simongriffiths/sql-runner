# road-secrets Specification

**Version:** 1.4 (draft)
**Date:** 2026-11-23
**Repository:** `sql-runner`
**Status:** Ready for build, subject to the spikes in Section 12 and the open questions in Section 16

---

## 1. Purpose

`road-secrets` is a per-user command-line tool that generates, stores and applies passwords for ROAD development and test environments.

It solves one problem. Passwords for database users and road-kit principals are set by hand and then forgotten. The tool generates every password itself and keeps it in the macOS Keychain. Nobody needs to choose or remember a password again.

It manages two kinds of credential:

- **Database users.** These are the users behind SQLcl saved connections. The tool changes the password in the database, stores it in the Keychain and re-saves every SQLcl connection that logs in as that user.
- **road-kit principals.** These are scaffold login users in `ROAD_PRINCIPALS`. The tool stores the password in the Keychain, applies it through the app's existing `bin/set-principal-password.sh` and writes it into the app's `config/local.env`.

The Keychain is the master copy. SQLcl's saved connections and each app's `config/local.env` are copies that the tool keeps up to date.

---

## 2. Scope

### 2.1 In scope

- Development and test environments only
- macOS on Apple silicon, running in a logged-in desktop session
- Unattended use by Claude Code running in the Claude desktop app on the same Mac
- Database users reached through SQLcl saved connections, including users that several saved connections share and proxy logins of the form `USER[SCHEMA]` (Section 3, item 7)
- road-kit principals set through `bin/set-principal-password.sh`
- Several databases, each reached through its own wallet and TNS name
- The ADMIN user of a database that serves no production environment (Section 3, item 6)

### 2.2 Out of scope

- **Production.** The tool refuses to create any entry whose environment is `prod`, any entry for a user that a production environment logs in as, and any ADMIN entry for a database that serves a production environment. Production passwords are never stored.
- iCloud sync, or sync of any other kind
- Export and import
- Linux, Windows and SSH-only sessions. An SSH session may be unable to read the Keychain. The tool must fail with a clear message in that case (Section 9.3).
- Changes to `bin/run-sql.sh`. The runner continues to use SQLcl saved connections exactly as it does today.
- Changes to `bin/set-principal-password.sh`, and to the scripts that read `config/local.env`

---

## 3. Background and constraints

These facts shaped the design. Do not change the design without revisiting them.

1. **SQLcl's saved-password store is only obfuscated.** Unattended connection by name requires an auto-login wallet. Any process running as the user can recover the password. The tool does not try to fix that. It treats SQLcl's store as a convenience copy.
2. **The Keychain cannot protect against processes running as the user either.** Unattended Claude Code runs must be able to read passwords. No lock or prompt can stand in their way. Security comes from three other measures: every managed password is for dev or test, every account has least privilege, and production passwords are never stored.
3. **Passwords must never appear on a command line.** Command-line arguments are visible through `ps` and land in shell history. This rule already governs `run-sql.sh` and `set-principal-password.sh`. It is why the tool is a compiled Swift binary that calls the Keychain API directly, and why it never shells out to `security add-generic-password -w`.
4. **Passwords must never reach a log.** `run-sql.sh` logs live under `logs/` and are tracked in git. The tool never runs password-bearing SQL through `run-sql.sh`. It drives SQLcl itself, with echo off, and scrubs SQLcl's output before showing it.
5. **The binary's identity must be stable.** Each Keychain entry carries an access list naming the programs that can read it without a prompt. macOS identifies a program by its path and code signature. The binary therefore lives at one fixed per-user path, outside every repository.
6. **Production is a property of the database, not only of the key.** A key's `env` segment says what the key is for. It cannot say what else the same database serves. ADMIN controls the whole database, so an ADMIN entry is allowed only for a database that serves no production environment. On 2026-11-23, road-atlas records road-blogger `prod` and road-beacon `prod` on quoratedb, so quoratedb's ADMIN password is a production password and is never stored. Today only roadkitdb's ADMIN can be managed. Claude Code sometimes needs ADMIN on a dev or test database. Keeping that ADMIN out of the tool would not stop that. It would only push the password into SQLcl's store or into a prompt. Recovery from a mistake relies on Autonomous Database's automatic backups.
7. **Saved connections share login users.** In road-atlas's scan of 2026-11-15, 142 of 159 saved connections log in as `LIVEHUB_DEPLOY` through a proxy (`LIVEHUB_DEPLOY[SCHEMA]`): 125 on quoratedb and 17 on roadkitdb. Three more log in as ADMIN on quoratedb. A password belongs to the database user, not to a connection, so changing it breaks every connection that logs in as that user. The tool therefore re-saves all of them, and keeps each one's proxy schema.
8. **road-atlas is the source of truth for where things run.** `environments.conf` says which app and environment runs on which database, schema, connection and ORDS host. `databases.conf` lists the databases. The tool reads both at run time and does not keep its own copy. It finds road-atlas at `$ROAD_ATLAS`, or else at `~/Projects/road-atlas`. Any check that needs road-atlas fails closed: if the files cannot be read, the tool refuses (exit 6).
9. **`config/local.env` is where the test scripts read the principal password (road-atlas `D-03`).** `get-test-token.sh`, `run-endpoint-tests.sh` and `run-browser-smoke.sh` read `ROAD_TEST_PASSWORD` from it. The tool does not change those scripts. It writes the new password into `config/local.env` in the same run that changes it, which is the "same sitting" rule `D-03` already states.
10. **Changing a principal's password logs it out everywhere (road-atlas `F-09`).** `set-principal-password.sh` updates `credentials_changed_at`, the global-logout epoch. Every live session for that principal ends.

---

## 4. Layout

| Item | Location |
|---|---|
| Source (Swift package) | `sql-runner/tools/road-secrets/` |
| Installer | `sql-runner/bin/install-road-secrets.sh` |
| Installed binary | `~/.local/bin/road-secrets` |
| Dedicated keychain | `~/Library/Keychains/road.keychain-db` |
| Word lists | `sql-runner/tools/road-secrets/Resources/adjectives.txt` and `nouns.txt` |
| road-atlas (read only) | `$ROAD_ATLAS`, default `~/Projects/road-atlas` |
| This spec | `sql-runner/spec/road-secrets-spec-v1.md` |

The project installer (`skills/sql-runner/scripts/install-sql-runner.sh`) must not copy `road-secrets` into target projects. It checks whether `~/.local/bin/road-secrets` exists. If it is missing, it prints a one-line pointer to `bin/install-road-secrets.sh` and carries on.

---

## 5. Keys

### 5.1 Format

Every entry is identified by one key string:

```
road/<app>/<env>/<kind>/<NAME>
```

| Segment | Rule | Example |
|---|---|---|
| `app` | Lowercase letters, digits and hyphens. The app's repository name. For an ADMIN entry, the database name instead (Section 5.5). | `road-cal` |
| `env` | Lowercase letters, digits and hyphens. Must not be `prod`. | `dev` |
| `kind` | `db` or `principal` | `principal` |
| `NAME` | The database user name or principal subject. Uppercase letters, digits and `_ . @ $ # -`. | `ALICE` |

A key that breaks any rule is rejected with exit 2. In particular, lowercase letters in `NAME` are rejected, not converted. Each entry therefore has exactly one spelling, which the approval rules in Section 11 rely on.

Examples:

```
road/road-cal/dev/db/ROAD_CAL_SCHEMA
road/road-cal/dev/principal/ALICE
road/roadkitdb/dev/db/ADMIN
```

### 5.2 Mapping to the Keychain

Each key is stored as one generic-password item:

| Keychain attribute | Value |
|---|---|
| Service | `road/<app>/<env>/<kind>` |
| Account | `<NAME>` |
| Label | Readable text, such as `road-cal dev principal ALICE` |
| Comment | `set <YYYY-MM-DD>` |
| Generic attribute | JSON metadata (Section 5.3) |

### 5.3 Metadata

Each entry carries a small JSON document:

For a `db` entry:

```json
{ "set_at": "2026-11-22T00:20:00Z", "db": "quoratedb",
  "sqlcl_connections": ["road_cal_dev"],
  "wallet": "/Users/simon/wallets/quoratedb", "tns": "quoratedb_high" }
```

For a `principal` entry:

```json
{ "set_at": "2026-11-22T00:20:00Z", "project": "/Users/simon/Projects/road-cal",
  "ords_url": "https://example.adb.uk-london-1.oraclecloudapps.com/ords" }
```

| Field | Meaning |
|---|---|
| `db` | The database name, derived from `tns` (Section 5.6) |
| `sqlcl_connections` | Every SQLcl saved connection that logs in as this user on this database, found by discovery (Section 7.3, step 4). Recorded for information. Discovery runs again on every `set`, `sync` and `check`. |
| `wallet` | The wallet directory for that database. The tool sets `TNS_ADMIN` to this path for every SQLcl process it starts. |
| `tns` | The TNS name (the alias in the wallet's `tnsnames.ora`) |
| `project` | The app's project root, where `config/local.env` lives |
| `ords_url` | The ORDS base URL for the app and environment |

All of these are supplied or derived the first time a key is set and reused afterwards. Several databases are therefore supported with no shared configuration file of the tool's own.

### 5.4 Previous values

While a change is in progress, the old password is kept as a separate item:

- Service `road-previous/<app>/<env>/<kind>`, same account.

The previous item is deleted once the change succeeds. `list` hides previous items unless given `--all`.

### 5.5 One ADMIN entry per database

ADMIN belongs to a database, not to an app. An ADMIN key therefore uses the database name as its `app` segment, as in `road/roadkitdb/dev/db/ADMIN`. `set` refuses an ADMIN key whose `app` segment is not the database name derived from its TNS name (exit 2). Each database can thus have at most one ADMIN entry, and `--via-admin` (Section 7.3) finds it without ambiguity.

### 5.6 Database names

The database name is the TNS name with its service suffix (`_high`, `_medium`, `_low`, `_tp` or `_tpurgent`) removed. It must match a `db` line with status `active` in road-atlas's `databases.conf`. Otherwise `set` exits 2. This is the same name road-atlas uses in `environments.conf`.

### 5.7 Production guard

Before `set` changes anything, it reads `environments.conf` and refuses with exit 6 when any of these is true:

- The key's `env` is `prod`.
- The key is an ADMIN key, and any `env` line with environment `prod` names the key's database.
- Any `env` line with environment `prod` names the key's `NAME` as its schema, or names one of the discovered connections as its connection.
- road-atlas cannot be read.

`--via-admin` cannot reach a production database, because no ADMIN entry for one can exist.

---

## 6. Password generation

### 6.1 Format

```
Adjective.Noun.nnn
```

For example, `Brave.Otter.042`.

- `Adjective` and `Noun` are chosen at random from the word lists, using the system's secure random generator (`SecRandomCopyBytes`). Each word starts with a capital letter and continues in lowercase.
- `nnn` is a random integer from 0 to 999, always written as three digits with leading zeros.
- If the password contains the user name or subject (ignoring case), generate another.

### 6.2 Word lists

- Two plain-text files, one word per line: about 1,000 adjectives and about 2,000 nouns.
- Common, everyday words of 4 to 8 letters, using letters only. Words that are offensive, easily misspelt or have more than one common spelling are excluded.
- The lists are part of the source and are reviewed by a person before the first release.

### 6.3 Why this format passes

Autonomous Database requires 12 to 30 characters, at least one uppercase letter, one lowercase letter and one digit, no double quotes, and no user name. With words of 4 to 8 letters, every password is 13 to 21 characters long. The capital letters, lowercase letters and digits are always present.

The dots must be checked in spike S2. Oracle requires a password containing characters other than letters, digits, `_`, `$` and `#` to be double-quoted in SQL. The tool always quotes passwords in `alter user`. S2 must confirm that SQLcl's `conn` and `-savepwd` accept a password containing dots.

The format contains no single quote, so it can be written single-quoted into `config/local.env` without escaping.

### 6.4 Strength

With the list sizes above there are about 2 billion possible passwords, or about 31 bits of randomness. This is a deliberate trade for typing convenience. It is acceptable because every managed password is for dev or test and every account has least privilege. Do not reuse this generator for anything else.

---

## 7. Commands

All commands take a key as their main argument. Any line printed by `list` can be pasted into another command.

| Command | Purpose |
|---|---|
| `init` | One-time setup of the dedicated keychain |
| `list [prefix] [--all]` | List keys. Never shows passwords. |
| `set <key> [options]` | Generate a new password and apply it everywhere |
| `sync <key>` | Push the Keychain password into every copy: SQLcl for `db`, `config/local.env` for `principal` |
| `get <key>` | Print the password to standard output |
| `copy <key>` | Put the password on the clipboard |
| `check <key>` | Prove the stored password works |
| `delete <key> [--yes]` | Remove the entry and any previous item |

### 7.1 `init`

1. If `~/Library/Keychains/road.keychain-db` exists, report it and exit 0.
2. Generate a random 32-character password for the keychain itself.
3. Store that password in the **login** keychain, as service `road-secrets/keychain-password`, account `road`. The user never sees or needs it.
4. Create the dedicated keychain with that password.
5. Set the keychain to never lock on a timer and never lock on sleep.
6. Add it to the user's keychain search list. It then appears in Keychain Access.

On each later run, the tool opens the dedicated keychain by path. If it is locked (for example after a restart), the tool unlocks it with the password held in the login keychain.

### 7.2 `list [prefix] [--all]`

Prints one line per entry, sorted by key:

```
road/road-cal/dev/db/ROAD_CAL_SCHEMA	2026-11-21	road-cal dev db ROAD_CAL_SCHEMA
```

The fields are key, date set and label, separated by tabs. A prefix narrows the output. For example, `list road/road-cal/dev` shows only road-cal's dev entries. `--all` also shows previous items, marked `(previous)`.

### 7.3 `set` for a `db` key

Options:

- `--connection <name>`, `--wallet <path>` and `--tns <name>`: one SQLcl saved connection that logs in as the user, the wallet directory and the TNS name. All three are required the first time a key is set. On later runs they are taken from the entry's metadata.
- `--via-admin`: change the password as ADMIN on the same database (see step 6).
- `--yes`: proceed without confirmation when more than one saved connection will be re-saved (step 4).

Steps:

1. **Resolve the connection.** Use the options, or else the entry's metadata. If neither exists, exit 2 with a message listing the missing options. Check that the wallet directory exists and that its `tnsnames.ora` contains the TNS name. Derive the database name (Section 5.6).
2. **Read the connection details.** Run `connmgr show <name>` in SQLcl and parse the user name and connect string. The login user is the part before any `[`, so `LIVEHUB_DEPLOY[AV_ACC]` logs in as `LIVEHUB_DEPLOY`. If the login user does not match the key's `NAME`, exit 2.
3. **Apply the production guard** (Section 5.7) and, for an ADMIN key, the one-per-database rule (Section 5.5).
4. **Discover every connection that logs in as this user.** Run `connmgr list`, then `connmgr show` for each saved connection, in one SQLcl session. Keep every connection whose login user is `NAME` and whose connect string resolves to the same database name, whatever its service suffix or proxy schema. Apply the production guard to the result. Print the number of connections and their names. If there is more than one, ask for confirmation at the terminal unless `--yes` is given. If standard input is not a terminal and `--yes` is absent, exit 2.
5. **Adopt the account if needed.** If `--via-admin` is absent and no current entry exists, the account has not been adopted yet. Ask for its current password at the terminal with echo off and use that as the old password. If standard input is not a terminal, exit 2 with a message suggesting `--via-admin`. This is also how the ADMIN entry for a database is first adopted.
6. **Store the new value first.** Generate a password. Copy the current entry (if any) to the previous item. Write the new password to the current entry.
7. **Change the password in the database.** Drive SQLcl through standard input, with echo off:
   - **Default (self-change):** connect with `conn -name <connection>`, then run `alter user <NAME> identified by "<new>" replace "<old>";`. The old password comes from the previous item, or from the terminal during adoption.
   - **With `--via-admin`:** find the ADMIN entry for the key's database (Section 5.5). If there is none, exit 2 with a message saying the ADMIN entry for this database must be adopted first, or that this database serves production and has none. Connect as ADMIN to the entry's TNS name, with `TNS_ADMIN` set to the entry's wallet. Then run `alter user <NAME> identified by "<new>";`. This is how an account whose password has been forgotten is adopted. It works because ADMIN does not need the old password. `--via-admin` cannot be used on the ADMIN entry itself.
8. **On failure:** restore the current entry from the previous item, or delete it if there was none. Show the scrubbed SQLcl error and exit 5.
9. **Re-save every discovered connection** with the new password, in one SQLcl session, keeping every other property, including the proxy schema. The method is decided by spike S2 (Section 12). If any re-save fails, keep the Keychain entry, because the database already has the new password. List the connections that failed, tell the user to run `sync` and exit 5.
10. **Finish.** Delete the previous item, update the metadata and print a one-line success message naming how many connections were re-saved. Never print the password.

### 7.4 `set` for a `principal` key

Options:

- `--project <path>`: the app's project root. It defaults to the entry's metadata, and then to the root of the git repository containing the current directory.
- `--ords-url <url>`: the ORDS base URL for the app and environment. Optional. If absent, the tool derives it from road-atlas: the `env` line for the key's app and environment names a database, and that database's `host` line gives `<host>/ords`. If road-atlas has no host for it, the URL is left unset. It is stored in the metadata and used by `check`.

Steps:

1. Confirm that the project root's directory name matches the key's `app`, and that `bin/set-principal-password.sh` exists there. Otherwise exit 2.
2. Apply the production guard's `env` rule (Section 5.7).
3. Print a one-line warning that every live session for this principal will end (Section 3, item 10).
4. Generate a password. Copy the current entry (if any) to the previous item. Write the new password to the current entry.
5. Run `bin/set-principal-password.sh --env <env> --subject <NAME>` from the project root. Write the password to its standard input twice, each followed by a newline. The script reads a password and then a confirmation.
6. If the script exits non-zero, restore the current entry from the previous item (or delete it), show the script's output and exit 5.
7. **Update `config/local.env`** (Section 7.11).
8. Delete the previous item and print a one-line success message.

### 7.5 `sync <key>`

For a `db` key, it discovers the connections again (Section 7.3, step 4), re-saves each with the Keychain password using the spike S2 method, then runs `connmgr test` on each and reports any that fail.

For a `principal` key, it updates `config/local.env` (Section 7.11).

Use `sync` on a new Mac, after reinstalling SQLcl, after adding a saved connection for a user the tool already manages, or after a `set` that ended with a copy failing.

### 7.6 `get <key>`

Prints the password followed by a newline, and nothing else, to standard output. This is for scripts and test runners. Exit 3 if the key does not exist.

### 7.7 `copy <key>`

Puts the password on the clipboard using `NSPasteboard`. Prints `copied <key>` to standard error. It is useful only at the Mac itself, or from a device sharing its clipboard through the same Apple ID.

### 7.8 `check <key>`

**For `db` keys,** it runs two checks and reports each one:

1. Connect through SQLcl as `<NAME>` to the entry's TNS name, using the Keychain password and the entry's wallet. Then run `select 1 from dual`. This proves the Keychain copy works.
2. Discover the connections again and run `connmgr test` on each. This proves SQLcl's copies work. Report the number that pass and name any that fail.

**For `principal` keys,** it runs two checks:

1. Call the scaffold login endpoint:
   - URL: `<ORDS base>/<API_BASE_PATH>/jwt-auth/login`
   - `<ORDS base>` comes from the entry's `ords_url` metadata
   - `API_BASE_PATH` comes from the project's `road.config`
   - Method `POST`, content type `application/json`, with a body carrying the subject and password. Read `jwt_scaffold_auth_api.authenticate_json` in road-kit to confirm the field names.
   - Use `URLSession`. The password then never appears in an argument list.

   A 200 response containing `access_token` passes. A 404 means the scaffold login is not deployed. That happens when the app is configured for external OIDC (an outside identity provider such as Auth0). Report that and exit 5. If the entry has no `ords_url`, report "skipped: no ORDS URL stored for this key".
2. If `config/local.env` names this principal (Section 7.11), confirm that its `ROAD_TEST_PASSWORD` equals the Keychain password, without printing either.

### 7.9 `delete <key> [--yes]`

Removes the entry and any previous item. Asks for confirmation unless `--yes` is given. It changes nothing in the database, in SQLcl or in `config/local.env`.

### 7.10 Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 2 | Invalid usage or invalid key |
| 3 | Key not found |
| 4 | Keychain error, including Keychain unavailable |
| 5 | Database, SQLcl, endpoint or `config/local.env` error |
| 6 | Refused by the production guard, including road-atlas unreadable |

### 7.11 Updating `config/local.env`

`config/local.env` names the test principal in `ROAD_TEST_USERNAME`, which defaults to `ADMIN` when unset or commented out.

- If `<project>/config/local.env` does not exist, print a pointer to `config/local.env.example` and the `D-03` rule, and change nothing. This is not a failure.
- If it exists and its test principal is not `NAME`, change nothing.
- Otherwise replace the value on the `export ROAD_TEST_PASSWORD=` line with the new password, single-quoted. If there is no such line, append one. Keep the file's permissions and every other line. Write to a temporary file in the same directory and rename it over the original.
- Before writing, confirm that `config/local.env` is ignored by git (`git check-ignore`). If it is not, refuse with exit 5. `D-03` records two repositories that once did not ignore it.
- If the write fails, keep the Keychain entry, because the principal already has the new password. Tell the user to run `sync` and exit 5.

---

## 8. Driving SQLcl

- Run SQLcl as a child process using `Process`. Write commands to its standard input. Never put a password in its argument list.
- The first lines written are `set echo off`, `set feedback off` and `set define off`.
- Capture standard output and standard error together. Before showing any output, replace every occurrence of the old or new password with `********`.
- Use `$SQLCL_BIN` if it is set. Otherwise use `sql` from `PATH`. Pass the environment through. Set `TNS_ADMIN` to the entry's wallet directory.
- Replace every occurrence of the ADMIN password in output with `********` as well, when one is used.
- Treat any `ORA-` or `SP2-` line, or a non-zero exit, as failure. This matches the run-sql spec. That spec counts SQLcl session errors as failures even when the exit code is 0.
- Run discovery and re-saving for many connections in one SQLcl session, not one process per connection.

---

## 9. Keychain access

### 9.1 Access lists

Every item the tool creates lists `~/.local/bin/road-secrets` as its only trusted program. Reads by the tool then raise no prompt. Other programs, including the `security` command-line tool, get a prompt.

### 9.2 Rebuilds

The binary has an ad-hoc signature. Each rebuild therefore changes its identity. After a rebuild, the first read of each item raises an "Always Allow" prompt on the Mac's screen. This is accepted. The installer must print a warning to that effect. It must also say that the user should not rebuild just before leaving an unattended run.

### 9.3 Unavailable Keychain

If the Keychain refuses access without user interaction, for example in an SSH session, exit 4 with this message:

```
road-secrets: the Keychain is not available in this session. Run from the desktop session on this Mac.
```

---

## 10. Installer: `bin/install-road-secrets.sh`

1. Check for Swift (`swift --version`). If it is missing, tell the user to install Apple's Xcode Command Line Tools with `xcode-select --install`, then exit 1.
2. Build with `swift build -c release` in `tools/road-secrets`.
3. Create `~/.local/bin` if needed. Copy the binary there.
4. Check whether `~/.local/bin` is on `PATH`. If it isn't, print the line to add to `~/.zshrc`.
5. Check that road-atlas can be found (Section 3, item 8). If it can't, print how to set `ROAD_ATLAS`.
6. Run `road-secrets init`.
7. Print the rebuild warning from Section 9.2.

The script must pass the repository's `make lint` (`bash -n` and `shellcheck`).

---

## 11. Documentation and skill changes

- **sql-runner `README.md`:** add a short "Passwords" section covering installation and the commands.
- **`skills/sql-runner/SKILL.md`:** add a rule. When a script or test needs a dev or test password, get it with `road-secrets get <key>` and pass it on through standard input or an environment variable. Never echo it, never write it to a file in a repository, and never ask the user for it. Never create or change an entry for `prod`. Always call the tool as `road-secrets`, never by its full path, and always write keys exactly as `list` prints them.
- **Approval gate for ADMIN work:** document in the README that the user should add these rules to the `ask` list in `~/.claude/settings.json`. That file applies to every project, and the Code tab of the desktop app reads it too.

  ```json
  {
    "permissions": {
      "ask": [
        "Bash(bin/run-sql.sh --env admin *)",
        "Bash(./bin/run-sql.sh --env admin *)",
        "Bash(road-secrets get *ADMIN)",
        "Bash(road-secrets copy *ADMIN)",
        "Bash(*/road-secrets get *ADMIN)",
        "Bash(*/road-secrets copy *ADMIN)"
      ]
    }
  }
  ```

  Claude Code then asks before running a script as ADMIN, or before reading an ADMIN password. The user approves, and the password comes from the saved SQLcl connection, which `sync` keeps current. Nobody types or pastes it. Because keys must be uppercase (Section 5.1), `*ADMIN` matches every spelling the tool accepts. The rules also match a road-kit test principal whose subject is `ADMIN`, the default in `config/local.env`. That costs one approval and is accepted. Claude Code's documentation says such rules are not a security boundary, because the same program can be called in other forms. The skill must therefore also tell Claude to always write `--env` as the first argument to `run-sql.sh`.
- **`../road-atlas`**, as required by `AGENTS.md`:
  - Add a ledger note that `road-secrets` exists and that road-kit's principal passwords can now be managed through it.
  - Amend `D-03`: the Keychain becomes the master copy of `ROAD_TEST_PASSWORD`, and `config/local.env` remains the copy the scripts read. A lost value is then recoverable with `road-secrets get`.
  - For each app adopted, change the `secrets` column of its `env` line in `environments.conf` to name the key, for example `road-secrets road/road-cal/dev/principal/ADMIN, copied to config/local.env`.

---

## 12. Spikes

Run these first, in order. Record each result in `docs/journal/`. If a spike fails, stop and report before building the affected part.

**S1. Dedicated keychain mechanics.** On the Mac mini's current macOS version, from a Swift binary:

- Create a file-based keychain at a given path, set it never to lock, and add it to the search list.
- Store its password in the login keychain, and unlock the dedicated keychain with it after a restart.
- Add, read, update and delete a generic-password item in the dedicated keychain, with an access list naming only the binary.
- Read the item from a Claude Code session in the Claude desktop app with no prompt.
- Rebuild the binary and confirm that exactly one "Always Allow" prompt appears, and none after it.

Several of the APIs involved, such as `SecKeychainCreate` and `SecAccessCreate`, are deprecated but still shipped. If they fail or prove fragile, fall back to the **login keychain**, using the same services and keys, and drop `init` steps 2 to 6. Report which path was taken.

**S2. Re-saving SQLcl connections.** Find a reliable way to replace the stored password of an existing saved connection while keeping its other properties, including any wallet or cloud configuration. Candidates:

- With `TNS_ADMIN` set to the entry's wallet: `conn -save <name> -savepwd -replace <user>/"<pwd>"@<tns>`
- The same, using `-cloudconfig` if a wallet zip proves more reliable than a wallet directory

Confirm that a password containing dots works, quoted and unquoted.

Confirm that a proxy connection (`USER[SCHEMA]`) keeps its proxy schema after re-saving. Confirm that `connmgr list` and `connmgr show` give enough to discover every connection for a user, and parse reliably.

Re-save all 17 `LIVEHUB_DEPLOY` connections on roadkitdb in one SQLcl session, and record how long it takes. Estimate the time for the 125 on quoratedb from that.

Verify with `connmgr test`. Confirm that the password never appears in SQLcl's output or history.

**S3. Piping into `set-principal-password.sh`.** The script reads with `read -rs` and has no check for a terminal. Confirm that it accepts the password twice on standard input when standard input is not a terminal, and that a login with that password then succeeds.

---

## 13. Tests

- **Unit tests (`swift test`):** key parsing and validation, the rejection of lowercase names, the `prod` refusal, ADMIN key naming, database-name derivation, the production guard against a fixture `environments.conf` and `databases.conf` (including a missing file), login-user parsing of `USER[SCHEMA]`, Keychain attribute mapping, password generation (run 10,000 generations and check length, character classes, the three-digit number and the user-name rule), word-list validation (letters only, 4 to 8 letters, no duplicates), `config/local.env` rewriting against fixtures (line present, line absent, commented `ROAD_TEST_USERNAME`, other principal) and output scrubbing.
- **Integration checklist (manual, recorded in `docs/journal/`):**
  1. `init` on a clean machine, then a second `init` reports that the keychain exists.
  2. Adopt roadkitdb's ADMIN by typing its current password, rotate it, then run `check`. All succeed.
  3. `set` for quoratedb's ADMIN exits 6.
  4. `set --via-admin` adopts a dev database user on roadkitdb. `set` by typing the current password adopts a dev database user on quoratedb. `check` passes both checks for each.
  5. A second `set` (self-change) rotates a password, then `check` passes.
  6. `set --via-admin` against a database whose ADMIN entry holds a wrong password fails, and the Keychain entry is restored.
  7. `set --yes` for `LIVEHUB_DEPLOY` on roadkitdb re-saves all 17 connections, and `check` reports all 17 passing.
  8. `set` for a user with several connections, with standard input not a terminal and no `--yes`, exits 2 and changes nothing.
  9. `sync` after deleting and recreating a SQLcl connection restores it.
  10. `set` for a principal in road-kit updates `config/local.env`, `check` passes against the dev ORDS endpoint, and `bin/get-test-token.sh` then works.
  11. `get` from a script in a Claude Code session runs with no prompt.
  12. `list`, `copy` and `delete` behave as specified.
  13. `set` for any key with environment `prod` exits 6, and `set` for the schema of a prod `env` line exits 6.
  14. `ps` during `set` shows no password in any argument list.

---

## 14. Build order

1. Spikes S1 to S3
2. Swift package skeleton, key parsing, password generator and unit tests
3. road-atlas reader and production guard
4. Keychain store (`init`, `list`, `get`, `copy`, `delete`)
5. SQLcl driver, connection discovery and output scrubbing
6. `db` commands (`set`, `sync`, `check`)
7. `principal` commands (`set`, `sync`, `check`) and `config/local.env` updating
8. Installer
9. README, skill and road-atlas updates
10. Integration checklist

---

## 15. Operating notes

These are not part of the build.

1. **Adopt ADMIN only where the database serves no production.** Today that is roadkitdb. Run `set road/roadkitdb/dev/db/ADMIN` with the ADMIN connection's options and type the current ADMIN password once. If it has been forgotten, reset it in the OCI console first. Other users on that database can then be adopted with `--via-admin`.
2. **On quoratedb, adopt users by typing their current password.** Its ADMIN is never stored, so `--via-admin` is not available there. For a user whose password has been forgotten, reset it as ADMIN by hand first.
3. **Production stays out.** Production ADMIN and application passwords are never stored by this tool.
4. **Rotate a principal when no one is relying on a live session for it.** Every session for it ends.

---

## 16. Open questions

1. **Does anything else hold `LIVEHUB_DEPLOY`'s password?** Resolved 2026-11-23: ai-live-hub may keep a copy in its `config/local.env`. That copy is superseded by the Keychain entry. Before adopting `LIVEHUB_DEPLOY`, check ai-live-hub's `config/local.env`, and after adopting it, have ai-live-hub read the password with `road-secrets get` instead.
2. **Should quoratedb's prod environments move off it?** Section 3, item 6 follows road-atlas as it stands. If road-blogger and road-beacon `prod` move to their own database, quoratedb's ADMIN becomes manageable with no change to the tool.

---

## Changes in 1.4

- A `db` entry now covers every saved connection that logs in as its user, including proxy logins. `set`, `sync` and `check` discover them each time (Sections 3.7, 7.3, 7.5, 7.8).
- Production is checked per database, from road-atlas. ADMIN of a database that serves production is refused, which today rules out quoratedb (Sections 3.6, 3.8, 5.7).
- ADMIN keys use the database name as `app`, so each database has at most one (Section 5.5).
- Principal `set` and `sync` write `config/local.env`, and `check` compares it (Sections 3.9, 7.4, 7.11).
- Lowercase names are rejected, not converted. The approval rules now cover `copy` and full-path calls (Sections 5.1, 11).
- The ORDS URL is derived from road-atlas when not given. `set` warns that a principal's sessions will end (Section 7.4).
