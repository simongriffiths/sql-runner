# Object Browser: Design Note

**Date:** 2026-11-22
**Repository:** `sql-runner`
**Status:** Design note only. Not ready for build. The full spec follows once its dependencies are in place (Section 5).

---

## 1. Purpose

The object browser is the second pane in the `sql-runner-panes` plugin. It shows an Oracle schema as a tree beside the conversation in Claude Code: tables, views, packages and other objects, with columns, sample rows and DDL on request.

The nearest existing tool is `dbview` (github.com/agntflw/claude-dbview), a Claude Code mod for PostgreSQL. It shows a tree of schemas and objects, with columns, sample rows, generated DDL and clickable foreign keys. It runs every query read-only, with a 10-second timeout. Nothing comparable exists for Oracle.

---

## 2. Decisions so far

1. **Read-only, for the user only.** The pane helps the person see the schema while Claude works. It gives Claude no new tools. It never runs DML or DDL.
2. **A read-only database user.** Each database gets a dedicated read-only user. Its password is a road-secrets entry, such as `road/road-cal/dev/db/ROADCAL_RO`, synced to a SQLcl saved connection.
3. **A cached catalogue.** The pane loads the whole catalogue (objects, columns, constraints, package members) in one SQLcl call, with `set sqlformat json`. It caches the result in memory and refreshes it on request. Browsing the tree needs no further database calls.
4. **Live calls only for detail.** Sample rows and DDL are fetched when the user asks for them, one SQLcl call each.
5. **A Node helper only if needed.** Each SQLcl call starts a Java process and a connection, which takes a few seconds. If live calls prove too slow, add a small local Node server using node-oracledb in Thin mode. It would hold a connection pool and get its password from `road-secrets get`. It is not built unless the first version shows the need.
6. **No MCP.** The pane talks to SQLcl or the Node helper directly. SQLcl's MCP server was rejected because it logs every request to `DBTOOLS$MCP_LOG` and tags each query as AI activity. The user's own browsing would pollute that audit trail.

---

## 3. Oracle-specific constraints

- **DDL for another user's objects needs extra privilege.** `DBMS_METADATA.GET_DDL` on objects owned by another schema needs `SELECT_CATALOG_ROLE` or equivalent. The read-only user must hold that role, or DDL must come from the schema owner's connection inside a read-only transaction. This needs deciding.
- **There is no per-statement timeout in SQLcl.** dbview's 10-second limit has no direct SQLcl equivalent. The options are the mods API's process timeout (which kills the session), a Resource Manager limit on the read-only user, or node-oracledb's call timeout in the Node helper.
- **Read-only must be enforced in the database.** The read-only user has only `CREATE SESSION` and `SELECT` grants. Each live call also runs inside `set transaction read only`.

---

## 4. Open questions

1. Which object types appear in the tree? Tables, views, materialised views, sequences, packages, procedures, functions, types and triggers are the likely set.
2. Should package members appear, with their signatures from `ALL_ARGUMENTS`? This is useful for PL/SQL-heavy apps like road-kit.
3. Should ORDS modules appear (module, template, handler and source)? For a ROAD app this may be the most useful view of all. No PostgreSQL tool has an equivalent.
4. One schema per pane, or a list of schemas the read-only user can see?
5. How large a sample: dbview offers 50, 100, 500 or 1,000 rows. Is that right for Oracle tables with LOB or vector columns?
6. Should invalid objects be marked in the tree? The catalogue query can return `STATUS` at no extra cost.

---

## 5. What must happen before the full spec

1. **The run-history pane is built.** The object browser reuses its plugin layout, project-root detection, test stubs and drawing patterns. Spike P1 confirms how panes draw in the desktop app.
2. **road-secrets spikes S1 and S2 are done.** These confirm how entries and SQLcl connections work in practice.
3. **One catalogue spike.** Time a single SQLcl call returning the full catalogue as JSON for road-kit's schema. Check its size against the mods API limits: 4 MiB for one file read, and 100,000 characters drawn in one tree.
4. **The privilege question in Section 3 is decided.**
