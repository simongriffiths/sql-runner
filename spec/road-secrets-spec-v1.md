# road-secrets Specification

**Version:** 1.6 (draft)
**Date:** 2026-11-27
**Repository:** `sql-runner`
**Status:** Ready for build. Spikes S1 to S3 are done (Section 12). Open questions are in Section 16.

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
5. **The binary's identity must be stable.** Each Keychain entry carries an access list naming the programs that can read it without a prompt. macOS identifies a program by its code signature, and a byte-identical copy at another path is trusted too. The binary has an ad-hoc signature, so every rebuild gives it a new identity (Section 9.2). It lives at one fixed per-user path, outside every repository.
6. **Production is a property of the database, not only of the key.** A key's `env` segment says what the key is for. It cannot say what else the same database serves. ADMIN controls the whole database, so an ADMIN entry is allowed only for a database that serves no production environment. On 2026-11-23, road-atlas records road-blogger `prod` and road-beacon `prod` on quoratedb, so quoratedb's ADMIN password is a production password and is never stored. Today only roadkitdb's ADMIN can be managed. Claude Code sometimes needs ADMIN on a dev or test database. Keeping that ADMIN out of the tool would not stop that. It would only push the password into SQLcl's store or into a prompt. Recovery from a mistake relies on Autonomous Database's automatic backups.
7. **Saved connections share login users.** On 2026-11-23, spike S2 found that 162 of 197 saved connections log in as `LIVEHUB_DEPLOY` through a proxy (`LIVEHUB_DEPLOY[SCHEMA]`): 145 on quoratedb and 17 on roadkitdb. road-atlas's scan of 2026-11-15 had found 142 of 159, and three more that log in as ADMIN on quoratedb. A password belongs to the database user, not to a connection, so changing it breaks every connection that logs in as that user. The tool therefore re-saves all of them, and keeps each one's proxy schema.
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
| Keychain | The user's login keychain (Section 9.1) |
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

A key that breaks any rule is rejected with exit 2, except that a key whose `env` is `prod` is refused with exit 6 as soon as it is read (Section 5.7). In particular, lowercase letters in `NAME` are rejected, not converted. Each entry therefore has exactly one spelling, which the approval rules in Section 11 rely on.

Examples:

```
road/road-cal/dev/db/ROAD_CAL_SCHEMA
road/road-cal/dev/principal/ALICE
road/roadkitdb/dev/db/ADMIN
```

### 5.2 Mapping to the Keychain

Each key is stored as one generic-password item in the user's login keychain:

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
  "wallet": "/Users/simon/wallets/Wallet_quoratedb.zip", "tns": "quoratedb_high" }
```

For a `principal` entry:

```json
{ "set_at": "2026-11-22T00:20:00Z", "project": "/Users/simon/Projects/road-cal",
  "ords_url": "https://example.adb.uk-london-1.oraclecloudapps.com/ords" }
```

| Field | Meaning |
|---|---|
| `db` | The database name, derived from `tns` (Section 5.6) |
| `sqlcl_connections` | Every SQLcl saved connection that logs in as this user on this database, found by discovery (Section 7.4, step 4). Recorded for information. Discovery runs again on every `set`, `sync` and `check`. |
| `wallet` | The wallet for that database: preferably the wallet zip, or else a wallet directory. Every SQLcl connect the tool makes with an explicit user and password uses `conn -cloudconfig` with this wallet (Section 8.1). |
| `tns` | The TNS name (the alias in the wallet's `tnsnames.ora`) |
| `project` | The app's project root, where `config/local.env` lives |
| `ords_url` | The ORDS base URL for the app and environment |

All of these are supplied or derived the first time a key is set and reused afterwards. Several databases are therefore supported with no shared configuration file of the tool's own.

### 5.4 Previous values

While a change is in progress, the old password is kept as a separate item:

- Service `road-previous/<app>/<env>/<kind>`, same account.

The previous item is deleted once the change succeeds. `list` hides previous items unless given `--all`.

### 5.5 One ADMIN entry per database

ADMIN belongs to a database, not to an app. An ADMIN key therefore uses the database name as its `app` segment, as in `road/roadkitdb/dev/db/ADMIN`. `add` refuses an ADMIN key whose `app` segment is not the database name derived from its TNS name (exit 2). Each database can thus have at most one ADMIN entry, and `--via-admin` (Section 7.4) finds it without ambiguity.

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

Oracle requires a password containing characters other than letters, digits, `_`, `$` and `#` to be double-quoted in SQL. The tool always quotes passwords, in `alter user` and in `conn`. Spike S2 confirmed that SQLcl's `conn` and `-savepwd` accept a password containing dots, quoted or unquoted.

The format contains no single quote, so it can be written single-quoted into `config/local.env` without escaping.

### 6.4 Strength

With the list sizes above there are about 2 billion possible passwords, or about 31 bits of randomness. This is a deliberate trade for typing convenience. It is acceptable because every managed password is for dev or test and every account has least privilege. Do not reuse this generator for anything else.

---

## 7. Commands

Every everyday command (`set`, `sync`, `get`, `copy`, `check` and `delete`) takes exactly one argument: the key, written exactly as `list` prints it. Any line printed by `list` can be pasted after one of these commands. They work from any folder, and an existing key needs no other options. A new entry is created with `add`, which takes the key's parts as named arguments (Section 7.3).

| Command | Purpose |
|---|---|
| `init` | Check that the tool can use the login keychain |
| `list [prefix] [--all]` | List keys. Never shows passwords. |
| `add --app <app> --env <env> --kind <db\|principal> --name <NAME> [details]` | Create a new entry and set its first password |
| `set <key>` | Generate a new password for an existing entry and apply it everywhere |
| `sync <key>` | Push the Keychain password into every copy: SQLcl for `db`, `config/local.env` for `principal` |
| `get <key>` | Print the password to standard output |
| `copy <key>` | Put the password on the clipboard |
| `check <key>` | Prove the stored password works |
| `delete <key> [--yes]` | Remove the entry and any previous item |

### 7.1 `init`

`init` creates nothing permanent. It writes, reads and deletes a test item, service `road-secrets/init-check`, in the login keychain. The item's access list names the binary, as for every item (Section 9.1). If all three steps succeed, it prints `road-secrets: login keychain OK` and exits 0. Otherwise it exits 4, with the message from Section 9.3 where that applies.

`init` can be run any number of times. There is no dedicated keychain. Spike S1 showed that after a rebuild, a dedicated keychain asks for its own password, which nobody knows (Section 12).

### 7.2 `list [prefix] [--all]`

Prints one line per entry, sorted by key:

```
road/road-cal/dev/db/ROAD_CAL_SCHEMA	2026-11-21	road-cal dev db ROAD_CAL_SCHEMA
```

The fields are key, date set and label, separated by tabs. A prefix narrows the output. For example, `list road/road-cal/dev` shows only road-cal's dev entries. `--all` also shows previous items, marked `(previous)`.

### 7.3 `add`

`add` creates an entry that does not exist yet, then sets its first password. It never asks a question, so it can run unattended.

Arguments:

- `--app`, `--env`, `--kind` and `--name`: the key's parts. All four are required. `--kind` must be `db` or `principal`, and the tool never guesses it. The parts are checked by the rules in Section 5.1. A lowercase `NAME` is rejected (exit 2), and `env` `prod` is refused (exit 6).
- For a `db` key, `--connection <name>`, `--wallet <zip|dir>` and `--tns <name>` are all required. They name one SQLcl saved connection that logs in as the user, the wallet and the TNS name. Optional: `--via-admin` (Section 7.4, step 7) and `--yes` (Section 7.4, step 4).
- For a `principal` key, these are optional: `--project <path>` (Section 7.5) and `--ords-url <url>`. If `--ords-url` is absent, the tool derives the URL from road-atlas: the `env` line for the key's app and environment names a database, and that database's `host` line gives `<host>/ords`. If road-atlas has no host for it, the URL is left unset.

Options that belong to the other kind are refused (exit 2).

Steps:

1. Build the key from the parts and validate it (Section 5.1).
2. If an entry for the key already exists, exit 2 with a message that points to `set <key>`.
3. **For a `db` key:**
   - Without `--via-admin`, read the user's current password from standard input. Print no prompt, and turn echo off when standard input is a terminal, so that the password can be piped in. If standard input is empty, exit 2 with a message suggesting `--via-admin`. This is also how the ADMIN entry for a database is first adopted.
   - Then follow Section 7.4 from step 1, using the details given.
4. **For a `principal` key:** follow Section 7.5 from step 1.
5. On success, print the key on standard output, as `list` would print it. Progress and warnings go to standard error.

### 7.4 `set` for a `db` key

`set <key>` takes only the key. The connection, wallet and TNS name come from the entry's metadata. If there is no entry, exit 3 with a message that points to `add`.

Options, for an existing key:

- `--via-admin`: change the password as ADMIN on the same database (step 7). Use it when the stored password no longer works.
- `--yes`: proceed without confirmation when more than one saved connection will be re-saved (step 4).

Steps:

1. **Resolve the connection.** For `set`, take it from the entry's metadata. For `add`, take it from the arguments. Check that the wallet (a zip or a directory) exists and that its `tnsnames.ora` contains the TNS name. Derive the database name (Section 5.6).
2. **Read the connection details.** Run `connmgr show <name>` in SQLcl and parse the user name and connect string. The login user is the part before any `[`, so `LIVEHUB_DEPLOY[AV_ACC]` logs in as `LIVEHUB_DEPLOY`. SQLcl keeps user names as they were typed, often in lowercase (`livehub_deploy[av_acc]`), so compare ignoring case. If the login user does not match the key's `NAME`, exit 2.
3. **Apply the production guard** (Section 5.7) and, for an ADMIN key, the one-per-database rule (Section 5.5).
4. **Discover every connection that logs in as this user.** Run `connmgr list -flat`, then `connmgr show` for each saved connection, in one SQLcl session (Section 8.2). Keep every connection whose login user equals `NAME`, ignoring case, and whose connect string resolves to the same database name, whatever its service suffix or proxy schema. Apply the production guard to the result. Print the number of connections and their names. If there is more than one and `--yes` is absent:
   - `set` asks for confirmation when standard input is a terminal, and otherwise exits 2.
   - `add` never asks, so it exits 2.
5. **Find the old password.** Without `--via-admin`, `set` uses the entry's current password, and `add` uses the one read from standard input.
6. **Store the new value first.** Generate a password. Copy the current entry (if any) to the previous item. Write the new password to the current entry.
7. **Change the password in the database.** Drive SQLcl through standard input, with echo off:
   - **Default (self-change):** connect directly as the user with the old password: `conn -cloudconfig <zip> <NAME>/"<old>"@<tns>` (Section 8.1). Then run `alter user <NAME> identified by "<new>" replace "<old>";`. The tool does not use `conn -name <connection>` here, because a proxy connection would log in as its proxy schema, not as `NAME`.
   - **With `--via-admin`:** find the ADMIN entry for the key's database (Section 5.5). If there is none, exit 2 with a message saying the ADMIN entry for this database must be added first, or that this database serves production and has none. Connect as ADMIN to the entry's TNS name with `conn -cloudconfig`, using the ADMIN entry's wallet (Section 8.1). Then run `alter user <NAME> identified by "<new>";`. This is how an account whose password has been forgotten is adopted. It works because ADMIN does not need the old password. `--via-admin` cannot be used on the ADMIN entry itself.
8. **On failure:** restore the current entry from the previous item, or delete it if there was none. Show the scrubbed SQLcl error and exit 5.
9. **Re-save every discovered connection** with the new password, in one SQLcl session, keeping its user, proxy schema and TNS name. Use the method in Section 8.1, then run `connmgr test` on each. If any re-save fails, keep the Keychain entry, because the database already has the new password. List the connections that failed, tell the user to run `sync` and exit 5.
10. **Finish.** Delete the previous item, update the metadata and print a one-line success message naming how many connections were re-saved. Never print the password.

### 7.5 `set` for a `principal` key

`set <key>` takes only the key. If there is no entry, exit 3 with a message that points to `add`.

**The project folder.** `set`, `sync` and `check` for a principal key find the app's project root in this order, so that they work from any folder:

1. `--project <path>`, if given. This is an optional override, and the path is stored for next time.
2. The `project` stored in the entry's metadata.
3. `$ROAD_PROJECTS/<app>`, if `ROAD_PROJECTS` is set.
4. `~/Projects/<app>`.

`add` uses the same order, without step 2. The ORDS URL comes from the metadata.

Steps:

1. Confirm that the project root's directory name matches the key's `app`, and that `bin/set-principal-password.sh` exists there. Otherwise exit 2, naming the folder tried and suggesting `--project`.
2. Apply the production guard's `env` rule (Section 5.7).
3. Print a one-line warning that every live session for this principal will end (Section 3, item 10).
4. Generate a password. Copy the current entry (if any) to the previous item. Write the new password to the current entry.
5. Run `bin/set-principal-password.sh --env <env> --subject <NAME>` from the project root. Write the password to its standard input twice, each followed by a newline. The script reads a password and then a confirmation. Spike S3 confirmed that this works when standard input is not a terminal.
6. If the script exits non-zero, restore the current entry from the previous item (or delete it), show the script's output and exit 5.
7. **Update `config/local.env`** (Section 7.12).
8. Delete the previous item and print a one-line success message.

### 7.6 `sync <key>`

For a `db` key, it discovers the connections again (Section 7.4, step 4), re-saves each with the Keychain password using the method in Section 8.1, then runs `connmgr test` on each and reports any that fail.

For a `principal` key, it updates `config/local.env` (Section 7.12), in the project folder found as in Section 7.5.

Use `sync` on a new Mac, after reinstalling SQLcl, after adding a saved connection for a user the tool already manages, or after a `set` that ended with a copy failing.

### 7.7 `get <key>`

Prints the password followed by a newline, and nothing else, to standard output. This is for scripts and test runners. Exit 3 if the key does not exist.

### 7.8 `copy <key>`

Puts the password on the clipboard using `NSPasteboard`. Prints `copied <key>` to standard error. It is useful only at the Mac itself, or from a device sharing its clipboard through the same Apple ID.

### 7.9 `check <key>`

**For `db` keys,** it runs two checks and reports each one:

1. Connect through SQLcl as `<NAME>` to the entry's TNS name with `conn -cloudconfig`, using the Keychain password and the entry's wallet. Then run `select 1 from dual`. This proves the Keychain copy works.
2. Discover the connections again and run `connmgr test` on each. This proves SQLcl's copies work. Report the number that pass and name any that fail.

**For `principal` keys,** it runs two checks:

1. Call the scaffold login endpoint:
   - URL: `<ORDS base>/<API_BASE_PATH>/jwt-auth/login`
   - `<ORDS base>` comes from the entry's `ords_url` metadata
   - `API_BASE_PATH` comes from the project's `road.config`
   - Method `POST`, content type `application/json`, with a body carrying the subject and password. Read `jwt_scaffold_auth_api.authenticate_json` in road-kit to confirm the field names.
   - Use `URLSession`. The password then never appears in an argument list.

   A 200 response containing `access_token` passes. A 404 means the scaffold login is not deployed. That happens when the app is configured for external OIDC (an outside identity provider such as Auth0). Report that and exit 5. If the entry has no `ords_url`, report "skipped: no ORDS URL stored for this key".
2. If `config/local.env` names this principal (Section 7.12), confirm that its `ROAD_TEST_PASSWORD` equals the Keychain password, without printing either.

### 7.10 `delete <key> [--yes]`

Removes the entry and any previous item. Asks for confirmation unless `--yes` is given. It changes nothing in the database, in SQLcl or in `config/local.env`.

### 7.11 Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 2 | Invalid usage or invalid key |
| 3 | Key not found |
| 4 | Keychain error, including Keychain unavailable |
| 5 | Database, SQLcl, endpoint or `config/local.env` error |
| 6 | Refused by the production guard, including road-atlas unreadable |

### 7.12 Updating `config/local.env`

`config/local.env` names the test principal in `ROAD_TEST_USERNAME`, which defaults to `ADMIN` when unset or commented out.

- If `<project>/config/local.env` does not exist, print a pointer to `config/local.env.example` and the `D-03` rule, and change nothing. This is not a failure.
- If it exists and its test principal is not `NAME`, change nothing.
- Otherwise replace the value on the `export ROAD_TEST_PASSWORD=` line with the new password, single-quoted. If there is no such line, append one. Keep the file's permissions and every other line. Write to a temporary file in the same directory and rename it over the original.
- Before writing, confirm that `config/local.env` is ignored by git (`git check-ignore`). If it is not, refuse with exit 5. `D-03` records two repositories that once did not ignore it.
- If the write fails, keep the Keychain entry, because the principal already has the new password. Tell the user to run `sync` and exit 5.

---

## 8. Driving SQLcl

- Run SQLcl as a child process using `Process`. Write commands to its standard input. Never put a password in its argument list.
- The first lines written are `set echo off`, `set feedback on` and `set define off`. Feedback must stay on. Spike S2 showed that with `set feedback off`, a failed `conn` prints nothing at all, and SQLcl still exits 0.
- Capture standard output and standard error together. Before showing any output, replace every occurrence of the old or new password with `********`. When the ADMIN password is used, replace that as well.
- Use `$SQLCL_BIN` if it is set. Otherwise use `sql` from `PATH`. Pass the environment through. Do not set `TNS_ADMIN` (Section 8.1).
- Run `show user` after every `conn`. If it does not report the expected user, the connect failed, even if nothing else says so.
- Treat any of these as failure:
  - an `ORA-` or `SP2-` line
  - a `Connection failed` line
  - an `already exists` line
  - a wrong user from `show user`
  - a non-zero exit

  This follows the run-sql spec, which counts SQLcl session errors as failures even when the exit code is 0.
- Run discovery and re-saving for many connections in one SQLcl session, not one process per connection.

### 8.1 Connecting and re-saving

Spike S2 tried two ways of giving SQLcl a database's wallet. Setting `TNS_ADMIN` to a wallet directory under `~/.dbtools/connections/` did not use the wallet: every connect retried for about 65 seconds, then failed with `ORA-12529`. `conn -cloudconfig <wallet.zip>` worked at once. The tool therefore uses `-cloudconfig` for every connect that gives a user and password:

```
conn -cloudconfig <zip> <login>/"<password>"@<tns>
conn -cloudconfig <zip> -save <name> -savepwd -replace <login>/"<password>"@<tns>
```

- `<login>` is the user as `connmgr show` gives it, including any proxy schema, such as `livehub_deploy[av_acc]`. The proxy schema survives the re-save.
- Always pass `-replace`. Without it, re-saving an existing name prints `A connection named <name> already exists`, saves nothing and exits 0.
- A re-save rewrites the connection from these arguments. Re-save the connections for one database at a time, with that database's wallet.
- If the entry's `wallet` is a directory, zip it at the start of the run. Put the zip in a new private temporary directory (mode 0700, file mode 0600) outside every repository, and delete it on exit.
- After re-saving, run `connmgr test` on each connection in one session.
- A saved connection used by name (`conn -name <connection>`, or `connmgr test`) keeps using its own stored wallet.

Measured in spike S2 on roadkitdb: re-saving 17 proxy connections in one session took 7.6 seconds, or about 0.44 seconds each. `connmgr test` on all 17 took 4.7 seconds. At that rate, re-saving quoratedb's 145 `LIVEHUB_DEPLOY` connections takes about 64 seconds.

### 8.2 Discovery

`connmgr list -flat` prints one name per line. `connmgr show <name>` prints `Name:`, `Connect String:` and `User:` lines, and both parse reliably. In spike S2, both commands for all 197 saved connections took about 3 seconds in one session.

---

## 9. Keychain access

### 9.1 Where items live

Every item is stored in the user's **login keychain**, which macOS unlocks at login. There is no dedicated keychain (Section 12, S1).

Every item the tool creates lists `~/.local/bin/road-secrets` as its only trusted program. Reads by the tool then raise no prompt. Other programs, including the `security` command-line tool, get a prompt. `list` reads only attributes, so it never raises a prompt.

### 9.2 Rebuilds

The binary has an ad-hoc signature, so each rebuild changes its identity. After a rebuild, the first read of each item raises an "Always Allow" prompt on the Mac's screen. Expect one prompt for each item read, not one in all. The user clicks Always Allow, and later reads of that item raise no prompt. Because the items are in the login keychain, the prompt asks at most for the user's own login password, never for a password nobody knows.

This is accepted. The installer must print a warning to that effect. It must also say that the user should not rebuild just before leaving an unattended run.

### 9.3 Unavailable Keychain

Exit 4 with the message below if the Keychain refuses access without user interaction, for example in an SSH session. Treat both of these statuses that way:

- `errSecInteractionNotAllowed`
- `errSecAuthFailed` (-25293). Spike S1 showed that this is what a refused access-list check returns when no prompt can be shown, for example after a rebuild.

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
- **`skills/sql-runner/SKILL.md`:** add a rule. When a script or test needs a dev or test password, get it with `road-secrets get <key>` and pass it on through standard input or an environment variable. Never echo it, never write it to a file in a repository, and never ask the user for it. Never create or change an entry for `prod`. Always call the tool as `road-secrets`, never by its full path, and always write keys exactly as `list` prints them. Create a new entry with `add`, never by guessing a key for `set`.
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

The spikes were run on 2026-11-23. The full results are in `docs/journal/2026-11-23.md` on the `spike/road-secrets` branch, and the spike code is in `tools/road-secrets/Spikes/` on that branch.

**S1. Dedicated keychain mechanics: failed, so the login keychain is used.** The deprecated APIs (`SecKeychainCreate`, `SecAccessCreate`) worked on macOS 27.3. Creating the keychain, unlocking it and every item operation passed, and reads from a Claude Code session in the desktop app raised no prompt. But after a rebuild, macOS asked for the dedicated keychain's own password. That password is random and held only in the login keychain, so nobody could answer the prompt. The tool therefore uses the login keychain, with the same services and keys, and `init` only checks access (Sections 4, 7.1 and 9).

**S2. Re-saving SQLcl connections: passed with `-cloudconfig`.**

- Setting `TNS_ADMIN` to a wallet directory failed with `ORA-12529`. `conn -cloudconfig <zip> -save <name> -savepwd -replace` works (Section 8.1).
- Dotted passwords work quoted and unquoted. Proxy schemas survive a re-save, and `connmgr test` passes.
- With `set feedback off`, a failed connect prints nothing and exits 0, so feedback stays on and every connect is checked with `show user` (Section 8).
- No password appeared in SQLcl's output, in its history or in any file written during the run.
- Discovery parses reliably. User names are stored as typed, often in lowercase.
- The timings and counts are in Sections 3.7, 8.1 and 8.2.

**S3. Piping into `set-principal-password.sh`: passed.** The script accepted the password twice on standard input when standard input was not a terminal. A login with `bin/get-test-token.sh` then succeeded.

---

## 13. Tests

- **Unit tests (`swift test`):** key parsing and validation, `add`'s argument validation, `add` on an existing key, `set` on a missing key, project-folder derivation, the rejection of lowercase names, the `prod` refusal, ADMIN key naming, database-name derivation, the production guard against a fixture `environments.conf` and `databases.conf` (including a missing file), login-user parsing of `USER[SCHEMA]`, Keychain attribute mapping, password generation (run 10,000 generations and check length, character classes, the three-digit number and the user-name rule), word-list validation (letters only, 4 to 8 letters, no duplicates), `config/local.env` rewriting against fixtures (line present, line absent, commented `ROAD_TEST_USERNAME`, other principal) and output scrubbing.
- **Integration checklist (manual, recorded in `docs/journal/`):**
  1. `init` succeeds, and a second `init` succeeds too. Neither leaves an item behind.
  2. `add` roadkitdb's ADMIN, piping its current password on standard input. Rotate it with `set <key>`, then run `check`. All succeed.
  3. `add` for quoratedb's ADMIN exits 6.
  4. `add --via-admin` adopts a dev database user on roadkitdb. `add` with the current password on standard input adopts a dev database user on quoratedb. `check` passes both checks for each.
  5. A second `set` (self-change) rotates a password, then `check` passes.
  6. `set --via-admin` against a database whose ADMIN entry holds a wrong password fails, and the Keychain entry is restored.
  6a. `add` for a key that exists exits 2. `set`, `sync` and `check` for a key that does not exist exit 3. `add` for a db user with empty standard input and no `--via-admin` exits 2.
  7. `add --via-admin --yes` for `LIVEHUB_DEPLOY` on roadkitdb re-saves all 17 connections, and `check` reports all 17 passing.
  8. `set` for a user with several connections, with standard input not a terminal and no `--yes`, exits 2 and changes nothing.
  9. `sync` after deleting and recreating a SQLcl connection restores it.
  10. `add`, then `set <key>`, for a principal in road-kit, run from a folder outside road-kit, updates `config/local.env`, `check` passes against the dev ORDS endpoint, and `bin/get-test-token.sh` then works.
  11. `get` from a script in a Claude Code session runs with no prompt.
  12. After a rebuild, the first `get` of an item raises one "Always Allow" prompt, which asks for nothing the user does not know. After Always Allow, a second `get` raises none.
  13. `list`, `copy` and `delete` behave as specified.
  14. `add` for any key with environment `prod` exits 6, and `add` for the schema of a prod `env` line exits 6.
  15. `ps` during `set` shows no password in any argument list.

---

## 14. Build order

1. Spikes S1 to S3 (done 2026-11-23, Section 12)
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

1. **Adopt ADMIN only where the database serves no production.** Today that is roadkitdb. Run `add --app roadkitdb --env dev --kind db --name ADMIN` with the ADMIN connection's `--connection`, `--wallet` and `--tns`, and give the current ADMIN password once on standard input. If it has been forgotten, reset it in the OCI console first. Other users on that database can then be added with `--via-admin`.
2. **On quoratedb, add users by giving their current password on standard input.** Its ADMIN is never stored, so `--via-admin` is not available there. For a user whose password has been forgotten, reset it as ADMIN by hand first.
3. **Production stays out.** Production ADMIN and application passwords are never stored by this tool.
4. **Rotate a principal when no one is relying on a live session for it.** Every session for it ends.

---

## 16. Open questions

1. **Does anything else hold `LIVEHUB_DEPLOY`'s password?** Resolved 2026-11-23: ai-live-hub may keep a copy in its `config/local.env`. That copy is superseded by the Keychain entry. Before adopting `LIVEHUB_DEPLOY`, check ai-live-hub's `config/local.env`, and after adopting it, have ai-live-hub read the password with `road-secrets get` instead.
2. **Should quoratedb's prod environments move off it?** Section 3, item 6 follows road-atlas as it stands. If road-blogger and road-beacon `prod` move to their own database, quoratedb's ADMIN becomes manageable with no change to the tool.
3. **Open item for road-kit, not this tool.** road-kit's `bin/get-test-token.sh` puts the password in curl's `-d` argument, which `ps` can show while curl runs. road-kit should send the body on standard input instead, with `--data @-`. This tool's own `check` uses `URLSession` and is not affected (Section 7.9).

---

## Changes in 1.6

- `set`, `sync`, `get`, `copy`, `check` and `delete` take exactly one argument, the key as `list` prints it, and work from any folder. An existing key needs no other options (Section 7).
- A new `add` command creates an entry from named parts: `--app`, `--env`, `--kind` (required, never guessed) and `--name`, with the kind's first-time details. It applies every existing rule, does the first set, never asks a question and prints the key (Section 7.3).
- `add` refuses a key that already exists (exit 2) and points to `set`. `set`, `sync` and `check` on a missing key exit 3 and point to `add` (Sections 7.3 to 7.5).
- The first-time options `--connection`, `--wallet`, `--tns` and `--ords-url` move from `set` to `add`. `set` keeps `--via-admin` and `--yes` for db keys, and `--project` as an optional override for principal keys (Sections 7.4, 7.5).
- Adoption no longer prompts. `add` reads a db user's current password from standard input, with no prompt and no echo. Empty standard input exits 2 and suggests `--via-admin` (Section 7.3).
- The project folder for a principal key is the `--project` override, else the stored project, else `$ROAD_PROJECTS/<app>`, else `~/Projects/<app>`. It no longer comes from the current directory's git repository (Section 7.5).
- These two points record how the build already works. A self-change logs in directly as the user with `conn -cloudconfig`, not with `conn -name`, because a proxy connection would log in as its proxy schema (Section 7.4, step 7). A key with `env` `prod` is refused with exit 6 as soon as it is read (Section 5.1).

## Changes in 1.5

- Spikes S1 to S3 are done. Section 12 records the results and points to the journal.
- Items live in the login keychain. The dedicated keychain is removed from the layout, and `init` only checks access (Sections 4, 5.2, 7.1, 9.1). After a rebuild, expect one "Always Allow" prompt for each item read (Section 9.2).
- Exit 4 also covers `errSecAuthFailed` (-25293) from a refused read (Section 9.3).
- SQLcl runs with `set feedback on`, and `show user` is checked after every connect. `already exists` and `Connection failed` count as failures (Section 8).
- Connects and re-saves use `conn -cloudconfig <wallet zip>`, with `-replace`, instead of setting `TNS_ADMIN` to a wallet directory. The `wallet` metadata holds a zip or a directory (Sections 5.3, 7.3, 7.8, 8.1).
- User names are compared ignoring case during discovery (Section 7.3).
- Counts and timings are updated: 145 `LIVEHUB_DEPLOY` connections on quoratedb and 197 saved connections in all. A full re-save on quoratedb takes about 64 seconds, and discovery about 3 seconds (Sections 3.7, 8.1, 8.2).
- road-kit's `get-test-token.sh` exposing the password to `ps` is recorded as an open item for road-kit (Section 16).

## Changes in 1.4

- A `db` entry now covers every saved connection that logs in as its user, including proxy logins. `set`, `sync` and `check` discover them each time (Sections 3.7, 7.3, 7.5, 7.8).
- Production is checked per database, from road-atlas. ADMIN of a database that serves production is refused, which today rules out quoratedb (Sections 3.6, 3.8, 5.7).
- ADMIN keys use the database name as `app`, so each database has at most one (Section 5.5).
- Principal `set` and `sync` write `config/local.env`, and `check` compares it (Sections 3.9, 7.4, 7.11).
- Lowercase names are rejected, not converted. The approval rules now cover `copy` and full-path calls (Sections 5.1, 11).
- The ORDS URL is derived from road-atlas when not given. `set` warns that a principal's sessions will end (Section 7.4).
