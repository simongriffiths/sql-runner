# ORDS Endpoint Tester: Design Note

**Date:** 2026-11-22
**Repository:** `sql-runner`
**Status:** Design note only. Not ready for build. The full spec follows once its dependencies are in place (Section 6).

---

## 1. Purpose

The endpoint tester is a pane in the `sql-runner-panes` plugin. It lets the user call an app's ORDS endpoints as a real principal from inside Claude Code, and take apart the JSON Web Token (JWT) used for the call.

Its main job is to explain failures. ORDS answers a bad token with a bare 401 or 403. The usual causes are a mismatch between the token and the schema's JWT profile, an expired token, or a missing scope. The tester checks each of these and says which one failed.

Claude edits a handler. The user tests it in the pane without leaving Claude Code or typing a password.

---

## 2. What it does

1. **List endpoints.** Show the app's modules, templates and handlers, with each handler's method and the privilege protecting it.
2. **Get a token.**
   - For a road-kit app using the scaffold, pick a principal. The pane logs in through `<ORDS base>/<API_BASE_PATH>/jwt-auth/login` with the principal's password from road-secrets. The ORDS base URL comes from the principal's road-secrets metadata.
   - For an app using an external identity provider such as Auth0, paste a token.
3. **Call the endpoint.** Choose a method, path parameters, query string and JSON body. Show the status, headers, time taken and response body.
4. **Inspect the token.**
   - Decode the header and claims: issuer (`iss`), subject (`sub`), audience (`aud`), scope, key ID (`kid`), and issued-at (`iat`), not-before (`nbf`) and expiry (`exp`) times. Show a countdown to expiry.
   - Check the signature against the issuer's published keys. For the road-kit scaffold these are at `<API_BASE_PATH>/jwt-auth/.well-known/jwks.json`. Mods have the browser's `crypto.subtle` API, so an RS256 signature check needs no extra library.
5. **Explain a 401 or 403.** Compare the token with the schema's JWT profile and the handler's privilege. Show one pass or fail line for each check:

   | Check | Rule |
   |---|---|
   | Issuer | The token's `iss` must match the profile's issuer |
   | Audience | The token's `aud` must match the profile's audience |
   | Signature | The signature must verify with a key from the profile's key URL |
   | Time | `exp` and `nbf` must hold, within the profile's allowed clock skew |
   | Age | Time since `iat` must be within the profile's allowed age, if one is set |
   | Scope | The token's scope must include the privilege protecting the handler |

   ORDS profiles can also accept role-based claims in place of scopes. The tester should report which mode the profile uses and check accordingly.
6. **Explain a 404.** ORDS publishes a catalogue of each schema's modules at `/ords/<schema>/metadata-catalog`. If a path returns 404, check whether ORDS lists the module at all.

---

## 3. Where the data comes from

- **Endpoints, from HTTP.** ORDS publishes an OpenAPI description of each module under `/ords/<schema>/open-api-catalog/`. OpenAPI is a standard, machine-readable API listing. If this gives methods, paths, parameters and privileges, the endpoint list needs no database access. Confirm this in a spike, including whether protected modules appear when the catalogue is fetched with a token.
- **The JWT profile and privileges, from the database.** The profile's issuer, audience, key URL, allowed skew and allowed age, and the mapping from privilege to path pattern, are in the schema's ORDS metadata views. road-kit already reads `USER_ORDS_JWT_PROFILE`. These `USER_` views show only the connected user's own schema. Reading them needs either the schema owner's connection inside a read-only transaction, or a grant to the read-only user. This is the same open question as in the object browser note.

---

## 4. Handling tokens and passwords

- Tokens are secrets. The pane keeps them in memory only. It shows them masked, with a button to reveal or copy.
- Tokens and passwords never go into the transcript, the log or `$.store`.
- An "Ask Claude" button may send the decoded claims, the check results and the response status. It never sends the token, its signature or any password.
- The pane refuses to fetch a production URL. It works only against environments road-secrets manages, which are dev and test.

---

## 5. Open questions

1. Is the OpenAPI catalogue complete enough to drive the endpoint list, or does the tester need the database views as well?
2. Should requests be saved as a named collection per app, like a lightweight Postman? This is useful, but it could also be left out of v1.
3. Should a run of saved requests become a smoke test, with a pass or fail result in the pane? This would overlap with road-kit's own tests.
4. How should the tester handle Deep Data Security once road-kit adopts it? The token may then carry data roles as well as scopes.

---

## 6. What must happen before the full spec

1. **The run-history pane is built,** with its plugin layout and drawing patterns.
2. **road-secrets is built,** including principals and their ORDS base URLs.
3. **One spike on the OpenAPI catalogue** against a road-kit dev app. Fetch the catalogue with and without a token, and record what it contains for a protected module.
4. **The database-access question in Section 3 is decided,** together with the same question in the object browser note.
