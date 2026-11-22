# road-secrets Specification

**Version:** 1.2 (draft)
**Date:** 2026-11-22
**Repository:** `sql-runner`
**Status:** Ready for build, subject to the spikes in Section 12

---

## 1. Purpose

`road-secrets` is a per-user command-line tool that generates, stores and applies passwords for ROAD development and test environments.

It solves one problem. Passwords for database users and road-kit principals are set by hand and then forgotten. The tool generates every password itself and keeps it in the macOS Keychain. Nobody needs to choose or remember a password again.

It manages two kinds of credential:

- **Database users.** These are the users behind SQLcl saved connections. The tool changes the password in the database, stores it in the Keychain and re-saves the SQLcl connection.
- **road-kit principals.** These are scaffold login users in `ROAD_PRINCIPALS`. The tool stores the password in the Keychain and applies it through the app's existing `bin/set-principal-password.sh`.

The Keychain is the master copy. SQLcl's saved connections are a copy that the tool keeps up to date.

---

## 2. Scope

### 2.1 In scope

- Development and test environments only
- macOS on Apple silicon, running in a logged-in desktop session
- Unattended use by Claude Code running in the Claude desktop app on the same Mac
- Database users reached through SQLcl saved connections
- road-kit principals set through `bin/set-principal-password.sh`
- Several databases, each reached through its own wallet and TNS name
- The ADMIN user of each dev or test database (Section 3, item 6)

### 2.2 Out of scope

- **Production.** The tool refuses to create any entry whose environment is `prod`. Production passwords are never stored.
- iCloud sync, or sync of any other kind
- Export and import
- Linux, Windows and SSH-only sessions. An SSH session may be unable to read the Keychain. The tool must fail with a clear message in that case (Section 9.3).
- Changes to `bin/run-sql.sh`. The runner continues to use SQLcl saved connections exactly as it does today.
- Changes to `bin/set-principal-password.sh`

---

## 3. Background and constraints

These facts shaped the design. Do not change the design without revisiting them.

1. **SQLcl's saved-password store is only obfuscated.** Unattended connection by name requires an auto-login wallet. Any process running as the user can recover the password. The tool does not try to fix that. It treats SQLcl's store as a convenience copy.
2. **The Keychain cannot protect against processes running as the user either.** Unattended Claude Code runs must be able to read passwords. No lock or prompt can stand in their way. Security comes from three other measures: every managed password is for dev or test, every account has least privilege, and production passwords are never stored.
3. **Passwords must never appear on a command line.** Command-line arguments are visible through `ps` and land in shell history. This rule already governs `run-sql.sh` and `set-principal-password.sh`. It is why the tool is a compiled Swift binary that calls the Keychain API directly, and why it never shells out to `security add-generic-password -w`.
4. **Passwords must never reach a log.** `run-sql.sh` logs live under `logs/` and are tracked in git. The tool never runs password-bearing SQL through `run-sql.sh`. It drives SQLcl itself, with echo off, and scrubs SQLcl's output before showing it.
5. **The binary's identity must be stable.** Each Keychain entry carries an access list naming the programs that can read it without a prompt. macOS identifies a program by its path and code signature. The binary therefore lives at one fixed per-user path, outside every repository.
6. **ADMIN is managed like any other user, in dev and test only.** Claude Code sometimes needs ADMIN. Keeping ADMIN out of the tool would not stop that. It would only push the password into SQLcl's store or into a prompt. An ADMIN entry gives Claude Code full control of that one database. Recovery from a mistake relies on Autonomous Database's automatic backups. Production ADMIN passwords are never stored, under the same rule as every other production password.

---

## 4. Layout

| Item | Location |
|---|---|
| Source (Swift package) | `sql-runner/tools/road-secrets/` |
| Installer | `sql-runner/bin/install-road-secrets.sh` |
| Installed binary | `~/.local/bin/road-secrets` |
| Dedicated keychain | `~/Library/Keychains/road.keychain-db` |
| Word lists | `sql-runner/tools/road-secrets/Resources/adjectives.txt` and `nouns.txt` |
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
| `app` | Lowercase letters, digits and hyphens. The app's repository name. | `road-cal` |
| `env` | Lowercase letters, digits and hyphens. Must not be `prod`. | `dev` |
| `kind` | `db` or `principal` | `principal` |
| `NAME` | The database user name or principal subject. Uppercase letters, digits and `_ . @ $ # -`. Input is converted to uppercase. | `ALICE` |

Examples:

```
road/road-cal/dev/db/ROADCAL_APP
road/road-cal/dev/principal/ALICE
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
{ "set_at": "2026-11-22T00:20:00Z", "sqlcl_connection": "roadcal_dev",
  "wallet": "/Users/simon/wallets/roadcal-dev", "tns": "roadcaldev_high" }
```

For a `principal` entry:

```json
{ "set_at": "2026-11-22T00:20:00Z", "ords_url": "https://example.adb.uk-london-1.oraclecloudapps.com/ords" }
```

| Field | Meaning |
|---|---|
| `sqlcl_connection` | The SQLcl saved connection the entry belongs to |
| `wallet` | The wallet directory for that database. The tool sets `TNS_ADMIN` to this path for every SQLcl process it starts. |
| `tns` | The TNS name (the alias in the wallet's `tnsnames.ora`) |
| `ords_url` | The ORDS base URL for the app and environment |

All of these are supplied the first time a key is set and reused afterwards. Several databases are therefore supported with no shared configuration file.

### 5.4 Previous values

While a change is in progress, the old password is kept as a separate item:

- Service `road-previous/<app>/<env>/<kind>`, same account.

The previous item is deleted once the change succeeds. `list` hides previous items unless given `--all`.

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
| `sync <key>` | Push the Keychain password into SQLcl (`db` only) |
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
road/road-cal/dev/db/ROADCAL_APP	2026-11-21	road-cal dev db ROADCAL_APP
```

The fields are key, date set and label, separated by tabs. A prefix narrows the output. For example, `list road/road-cal/dev` shows only road-cal's dev entries. `--all` also shows previous items, marked `(previous)`.

### 7.3 `set` for a `db` key

Options:

- `--connection <name>`, `--wallet <path>` and `--tns <name>`: the SQLcl saved connection, wallet directory and TNS name. All three are required the first time a key is set. On later runs they are taken from the entry's metadata.
- `--via-admin`: change the password as ADMIN on the same database (see step 4).

Steps:

1. **Resolve the connection.** Use the options, or else the entry's metadata. If neither exists, exit 2 with a message listing the missing options. Check that the wallet directory exists and that its `tnsnames.ora` contains the TNS name.
2. **Read the connection details.** Run `connmgr show <name>` in SQLcl and parse the user name and connect string. If the user name does not match the key's `NAME`, exit 2. If `--via-admin` is absent and no current entry exists, the account has not been adopted yet. Ask for its current password at the terminal with echo off and use that as the old password. If standard input is not a terminal, exit 2 with a message suggesting `--via-admin`. This is also how the ADMIN entry for a database is first adopted.
3. **Store the new value first.** Generate a password. Copy the current entry (if any) to the previous item. Write the new password to the current entry.
4. **Change the password in the database.** Drive SQLcl through standard input, with echo off:
   - **Default (self-change):** connect with `conn -name <connection>`, then run `alter user <NAME> identified by "<new>" replace "<old>";`. The old password comes from the previous item, or from the terminal during adoption.
   - **With `--via-admin`:** find the ADMIN entry whose `wallet` and `tns` metadata match this entry. If there is none, exit 2 with a message saying the ADMIN entry for this database must be adopted first. Connect as ADMIN to the entry's TNS name, with `TNS_ADMIN` set to the entry's wallet. Then run `alter user <NAME> identified by "<new>";`. This is how an account whose password has been forgotten is adopted. It works because ADMIN does not need the old password. `--via-admin` cannot be used on the ADMIN entry itself.
5. **On failure:** restore the current entry from the previous item, or delete it if there was none. Show the scrubbed SQLcl error and exit 5.
6. **Re-save the SQLcl connection** with the new password, keeping every other property. The method is decided by spike S2 (Section 12). On failure, keep the Keychain entry, because the database already has the new password. Tell the user to run `sync` and exit 5.
7. **Finish.** Delete the previous item, update the metadata and print a one-line success message. Never print the password.

### 7.4 `set` for a `principal` key

Options:

- `--project <path>`: the app's project root. It defaults to the root of the git repository containing the current directory.
- `--ords-url <url>`: the ORDS base URL for the app and environment. Optional. If given, it is stored in the metadata and used by `check`.

Steps:

1. Confirm that the project root's directory name matches the key's `app`, and that `bin/set-principal-password.sh` exists there. Otherwise exit 2.
2. Generate a password. Copy the current entry (if any) to the previous item. Write the new password to the current entry.
3. Run `bin/set-principal-password.sh --env <env> --subject <NAME>` from the project root. Write the password to its standard input twice, each followed by a newline. The script reads a password and then a confirmation.
4. If the script exits non-zero, restore the current entry from the previous item (or delete it), show the script's output and exit 5.
5. Delete the previous item and print a one-line success message.

### 7.5 `sync <key>`

For `db` keys only. Re-saves the SQLcl connection named in the metadata with the Keychain password, using the spike S2 method. It then runs `connmgr test <name>`. For a `principal` key, exit 2 with "nothing to sync".

Use `sync` on a new Mac, after reinstalling SQLcl, or after step 6 of `set` fails.

### 7.6 `get <key>`

Prints the password followed by a newline, and nothing else, to standard output. This is for scripts and test runners. Exit 3 if the key does not exist.

### 7.7 `copy <key>`

Puts the password on the clipboard using `NSPasteboard`. Prints `copied <key>` to standard error. It is useful only at the Mac itself, or from a device sharing its clipboard through the same Apple ID.

### 7.8 `check <key>`

**For `db` keys,** it runs two checks and reports each one:

1. Connect through SQLcl as `<NAME>` to the entry's TNS name, using the Keychain password and the entry's wallet. Then run `select 1 from dual`. This proves the Keychain copy works.
2. Run `connmgr test <name>`. This proves SQLcl's copy works.

**For `principal` keys,** it calls the scaffold login endpoint:

- URL: `<ORDS base>/<API_BASE_PATH>/jwt-auth/login`
- `<ORDS base>` comes from the entry's `ords_url` metadata
- `API_BASE_PATH` comes from the project's `road.config`
- Method `POST`, content type `application/json`, with a body carrying the subject and password. Read `jwt_scaffold_auth_api.authenticate_json` in road-kit to confirm the field names.
- Use `URLSession`. The password then never appears in an argument list.

A 200 response containing `access_token` passes. A 404 means the scaffold login is not deployed. That happens when the app is configured for external OIDC (an outside identity provider such as Auth0). Report that and exit 5. If the entry has no `ords_url`, report "skipped: no ORDS URL stored for this key" and exit 0.

### 7.9 `delete <key> [--yes]`

Removes the entry and any previous item. Asks for confirmation unless `--yes` is given. It changes nothing in the database or in SQLcl.

### 7.10 Exit codes

| Code | Meaning |
|---|---|
| 0 | Success |
| 2 | Invalid usage or invalid key |
| 3 | Key not found |
| 4 | Keychain error, including Keychain unavailable |
| 5 | Database, SQLcl or endpoint error |
| 6 | Refused, for example an environment of `prod` |

---

## 8. Driving SQLcl

- Run SQLcl as a child process using `Process`. Write commands to its standard input. Never put a password in its argument list.
- The first lines written are `set echo off`, `set feedback off` and `set define off`.
- Capture standard output and standard error together. Before showing any output, replace every occurrence of the old or new password with `********`.
- Use `$SQLCL_BIN` if it is set. Otherwise use `sql` from `PATH`. Pass the environment through. Set `TNS_ADMIN` to the entry's wallet directory.
- Replace every occurrence of the ADMIN password in output with `********` as well, when one is used.
- Treat any `ORA-` or `SP2-` line, or a non-zero exit, as failure. This matches the run-sql spec. That spec counts SQLcl session errors as failures even when the exit code is 0.

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
5. Run `road-secrets init`.
6. Print the rebuild warning from Section 9.2.

The script must pass the repository's `make lint` (`bash -n` and `shellcheck`).

---

## 11. Documentation and skill changes

- **sql-runner `README.md`:** add a short "Passwords" section covering installation and the commands.
- **`skills/sql-runner/SKILL.md`:** add a rule. When a script or test needs a dev or test password, get it with `road-secrets get <key>` and pass it on through standard input or an environment variable. Never echo it, never write it to a file in a repository, and never ask the user for it. Never create or change an entry for `prod`.
- **`../road-atlas`:** add a ledger note that `road-secrets` exists, as required by `AGENTS.md`. The note should say that road-kit's principal passwords can now be managed through it.

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

**S2. Re-saving a SQLcl connection.** Find a reliable way to replace the stored password of an existing saved connection while keeping its other properties, including any wallet or cloud configuration. Candidates:

- With `TNS_ADMIN` set to the entry's wallet: `conn -save <name> -savepwd -replace <user>/"<pwd>"@<tns>`
- The same, using `-cloudconfig` if a wallet zip proves more reliable than a wallet directory

Confirm that a password containing dots works, quoted and unquoted.

Verify with `connmgr test`. Confirm that the password never appears in SQLcl's output or history.

**S3. Piping into `set-principal-password.sh`.** Confirm that the script accepts the password twice on standard input when standard input is not a terminal, and that a login with that password then succeeds.

---

## 13. Tests

- **Unit tests (`swift test`):** key parsing and validation, uppercase conversion, the `prod` refusal, Keychain attribute mapping, password generation (run 10,000 generations and check length, character classes, the three-digit number and the user-name rule), word-list validation (letters only, 4 to 8 letters, no duplicates) and output scrubbing.
- **Integration checklist (manual, recorded in `docs/journal/`):**
  1. `init` on a clean machine, then a second `init` reports that the keychain exists.
  2. `set --via-admin` adopts a dev database user on one database, and a second user on a different database. `check` passes both checks for each.
  3. A second `set` (self-change) rotates the password, then `check` passes.
  4. `set --via-admin` against a database whose ADMIN entry holds a wrong password fails, and the Keychain entry is restored.
  5. `sync` after deleting and recreating the SQLcl connection restores it.
  6. `set --ords-url` for a principal in road-kit, then `check` passes against the dev ORDS endpoint.
  7. `get` from a script in a Claude Code session runs with no prompt.
  8. `list`, `copy` and `delete` behave as specified.
  9. `set` for any key with environment `prod` exits 6.
  10. Adopting a database's ADMIN entry by typing its current password, then rotating it, then running `check`, all succeed.
  11. `ps` during `set` shows no password in any argument list.

---

## 14. Build order

1. Spikes S1 to S3
2. Swift package skeleton, key parsing, password generator and unit tests
3. Keychain store (`init`, `list`, `get`, `copy`, `delete`)
4. SQLcl driver and output scrubbing
5. `db` commands (`set`, `sync`, `check`)
6. `principal` commands (`set`, `check`)
7. Installer
8. README, skill and road-atlas updates
9. Integration checklist

---

## 15. Operating notes

These are not part of the build.

1. **Adopt each database's ADMIN entry first.** Run `set road/<app>/<env>/db/ADMIN` with the ADMIN connection's options and type the current ADMIN password once. If it has been forgotten, reset it in the OCI console first. Other users on that database can then be adopted with `--via-admin`.
2. **Production stays out.** Production ADMIN and application passwords are never stored by this tool.
