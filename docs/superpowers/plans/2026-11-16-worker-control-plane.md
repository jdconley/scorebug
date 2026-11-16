# Worker Control Plane Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Run Scorebug's API as a Cloudflare Worker at `scorebug.live`, with:

- Google sign-in;
- a private-beta allowlist with an admin page for JD;
- teams with owners, members and invites;
- each team's matches and scoring in a per-team Durable Object, reusing
  today's match and scoring code.

**Architecture:**

- **Stores on a narrow interface:** the existing stores (`MatchStore`,
  `MediaStore`, `AccountStore`) move from `node:sqlite` to a small `SqlDb`
  interface. It has two adapters: Node (tests, the old server until removal)
  and Durable Object SQLite (production).
- **Worker:** a Hono app owns people, sessions, teams and routing in D1. It
  forwards match traffic to a `TeamObject` Durable Object per team.
- **TeamObject:** it serves today's `matchesRoutes` over its own SQLite, with
  the owner-device check swapped for a trusted team-member check.

**Tech Stack:** Cloudflare Workers, Durable Objects (SQLite storage), D1,
Workers Rate Limiting bindings, Hono 4, zod 4, Wrangler 4, Vitest 4 with
`@cloudflare/vitest-pool-workers` 0.23 (peer `vitest ^4.1.0`), and the
`nodejs_compat` flag for `node:crypto` and `Buffer`.

**Spec:** `docs/superpowers/specs/2026-11-16-hosted-cloudflare-design.md`
(sections "People, access and teams", "Control plane on Workers",
"Build order" step 1, "Deploys").

**Not in this plan:**

- YouTube connections, Stream, containers and Go Live (plan 3, after the
  spike);
- web pages for Google verification (plan 4);
- the iPhone app (plan 5);
- deleting self-hosting (plan 6).

The old Node server keeps building and passing its tests until plan 6. This
plan only adds to it.

## Global Constraints

- Public origin: `PUBLIC_URL=https://scorebug.live`. App sign-in callback:
  `scorebug://auth`. Team invite links: `https://scorebug.live/invite/<code>`.
  Match join links: `https://scorebug.live/join/<code>`.
- Sign-in scopes are exactly `openid email profile`. No YouTube scope in this
  plan.
- Emails are compared trimmed and lowercased everywhere: the allowlist,
  invites and people.
- Only Google identities with `email_verified: true` can sign in.
- Roles are exactly `owner` and `member`. A team has at least one owner at
  all times.
- One active match per team. The Durable Object's unique `one_active_match`
  index enforces it, as today.
- Session tokens: 32 random bytes, base64url. D1 stores only the SHA-256 hex.
- Sign-in tickets are single use, with a 2-minute TTL, bound to the SHA-256
  of the app's PKCE-style verifier.
- Team invite codes: 8 characters from `INVITE_CODE_ALPHABET`. Default expiry
  is 14 days, allowed range 1–30 days, and they're multi-use until expiry or
  revocation. An invite with an email can only be accepted by that email.
- Admin page access: `ADMIN_EMAILS`, a comma-separated Worker variable,
  initially JD's email. The page is only reachable through a cookie set by the
  Google web sign-in.
- The Durable Object is never reachable from the internet. Only the Worker
  calls it, and the Worker always overwrites `x-scorebug-member`.
- Every JSON response sends `Cache-Control: no-store`, as today.

## Review Focus

- **Email case and spaces.** `" JD.Conley@Gmail.com "` on the allowlist must
  match a Google sign-in for `jd.conley@gmail.com`. Pinned in Task 3, step 1
  (`allowlist matches case-insensitively`).
- **Unverified Google email.** An identity with `email_verified: false`
  never gets a ticket, even if the email is on the allowlist. Pinned in
  Task 3, step 1 (`rejects unverified email`).
- **Consent cancelled.** Google redirecting back with `error=access_denied`
  lands on `scorebug://auth?status=cancelled`, not a 500. Pinned in Task 3,
  step 1 (`cancelled consent redirects to app`).
- **Match ID collision across teams.** Match IDs come from the client. Team B
  creating a match with team A's match ID gets `409 match_id_taken` and must
  never route to team A. Pinned in Task 5, step 1
  (`match id taken by another team`).
- **Two phones create a match at once.** The second gets
  `409 match_in_flight` with the active snapshot, exactly as today.
  Pinned in Task 5, step 1 (`second concurrent create sees active match`).

---

## File Structure

Changes in `apps/control-plane/`:

| Path                                                                 | Responsibility                                                                               |
| -------------------------------------------------------------------- | -------------------------------------------------------------------------------------------- |
| `src/sql.ts`                                                         | `SqlDb` interface and `SqlValue` type                                                        |
| `src/sql-node.ts`                                                    | `openNodeSqlite(path)`: `node:sqlite` adapter with today's PRAGMAs                           |
| `src/sql-durable.ts`                                                 | `durableObjectSql(storage)`: Durable Object SQLite adapter                                   |
| `src/matches-store.ts`, `src/media-store.ts`, `src/account-store.ts` | take `SqlDb` instead of `DatabaseSync`                                                       |
| `src/routes/matches.ts`, `src/routes/account.ts`                     | take a `MatchAccess` option instead of hard-coding owner devices                             |
| `src/worker/env.ts`                                                  | `Env` bindings type                                                                          |
| `src/worker/index.ts`                                                | Worker entry: `export default { fetch }`, `export { TeamObject }`                            |
| `src/worker/app.ts`                                                  | `createWorkerApp(deps)`: Hono app                                                            |
| `src/worker/google.ts`                                               | `GoogleOAuth` interface and the real Google implementation                                   |
| `src/worker/directory.ts`                                            | D1 queries: people, beta, sessions, tickets, teams, memberships, team invites, match routing |
| `src/worker/state.ts`                                                | HMAC-signed OAuth `state` and route-code hashing                                             |
| `src/worker/auth-routes.ts`                                          | `/v1/auth/*`, `/v1/me`                                                                       |
| `src/worker/team-routes.ts`                                          | `/v1/teams/*`, `/v1/team-invites/accept`                                                     |
| `src/worker/match-forwarding.ts`                                     | forwards match routes to `TeamObject`                                                        |
| `src/worker/team-object.ts`                                          | `TeamObject` Durable Object hosting `matchesRoutes`                                          |
| `src/worker/admin-page.ts`                                           | `/admin`: beta list page and form posts                                                      |
| `migrations/0001_initial.sql`                                        | D1 schema                                                                                    |
| `wrangler.jsonc`                                                     | Worker, D1, Durable Object, rate limits, custom domain                                       |
| `tsconfig.worker.json`                                               | type-checks `src/worker` against Workers types                                               |
| `vitest.worker.config.ts`                                            | Workers-pool test config                                                                     |
| `test-worker/*.test.ts`                                              | Worker tests                                                                                 |

Repo root:

| Path                           | Responsibility                                      |
| ------------------------------ | --------------------------------------------------- |
| `.github/workflows/ci.yml`     | adds a Worker test step to the TypeScript job       |
| `.github/workflows/deploy.yml` | applies D1 migrations and deploys on push to `main` |

---

### Task 1: `SqlDb` interface and store port

**Files:**

- Create: `apps/control-plane/src/sql.ts`, `apps/control-plane/src/sql-node.ts`, `apps/control-plane/src/sql-durable.ts`
- Modify: `apps/control-plane/src/matches-store.ts` (constructor and all `this.db.prepare` calls), `src/media-store.ts`, `src/account-store.ts`, `src/app.ts:36`, `src/admin.ts:32`
- Test: `apps/control-plane/test/sql-node.test.ts`. The existing suites must pass unchanged, apart from how they construct stores.

**Interfaces:**

- Produces:
    ```ts
    export type SqlValue = string | number | null | Uint8Array;
    export interface SqlDb {
      exec(sql: string): void;                       // multi-statement DDL
      get<T>(sql: string, ...params: SqlValue[]): T | undefined;
      all<T>(sql: string, ...params: SqlValue[]): T[];
      run(sql: string, ...params: SqlValue[]): { changes: number };
      transaction<T>(body: () => T): T;              // nested calls run inline in the outer transaction
      close(): void;
    }
    export function openNodeSqlite(path: string): SqlDb;                    // sql-node.ts
    export function durableObjectSql(storage: DurableObjectStorage): SqlDb; // sql-durable.ts
    // matches-store.ts
    constructor(db: SqlDb, credentialKey: string, now?: () => number)
    ```
- **Behavior changes:**
    - **Schema version:** a `schema_meta(key TEXT PRIMARY KEY, value TEXT)`
      row `('version','5')` replaces `PRAGMA user_version`. Durable Objects
      reject that pragma, and no database is deployed, so nothing migrates.
      Refuse to open a database whose version is greater than 5
      (`unsupported_database_version`), as today.
    - **PRAGMAs:** they move into `openNodeSqlite`.
    - **Transactions:** in `durableObjectSql`, `transaction` uses
      `storage.transactionSync`.

- [ ] **Step 1: Write the failing tests** in `test/sql-node.test.ts`:
    - `rolls back a failed transaction`: insert inside
      `db.transaction(() => { db.run(insert); throw new Error('x') })`; expect
      `db.all('SELECT * FROM t')` to have length 0.
    - `nested transaction joins the outer one`: an inner `transaction`
      inserts, the outer one then throws; expect 0 rows.
    - `get returns undefined for no row`.
    - `refuses a newer schema`: write `schema_meta` version `'6'`, then
      `new MatchStore(db, key)` throws `unsupported_database_version`.

- [ ] **Step 2: Run** `pnpm --filter @scorebug/control-plane test -- sql-node`
      Expected: FAIL, because the module `../src/sql-node.js` doesn't exist.

- [ ] **Step 3: Implement** `sql.ts`, `sql-node.ts` and `sql-durable.ts`, then
      port the three stores and their callers. `test/helpers.ts` and every
      `new MatchStore(':memory:', …)` in tests become
      `new MatchStore(openNodeSqlite(':memory:'), …)`.

- [ ] **Step 4: Run** `pnpm --filter @scorebug/control-plane test && pnpm --filter @scorebug/control-plane typecheck`
      Expected: PASS, with every existing test green.

- [ ] **Step 5: Commit** `refactor(control-plane): stores run on a SqlDb interface`

### Task 2: Worker scaffold, D1 schema, test pool, CI

**Files:**

- Create: `apps/control-plane/wrangler.jsonc`, `migrations/0001_initial.sql`, `src/worker/env.ts`, `src/worker/index.ts`, `src/worker/app.ts`, `tsconfig.worker.json`, `vitest.worker.config.ts`, `test-worker/health.test.ts`
- Modify: `apps/control-plane/package.json` (devDependencies `wrangler`, `@cloudflare/vitest-pool-workers`, `@cloudflare/workers-types`; scripts below), `.github/workflows/ci.yml` (TypeScript job runs `pnpm --filter @scorebug/control-plane test:worker`)

**Interfaces:**

- Produces:
    ```ts
    // env.ts
    export interface Env {
        DB: D1Database;
        TEAM: DurableObjectNamespace<import('./team-object.js').TeamObject>;
        AUTH_LIMIT: RateLimit; // 20 requests / 60 s per client IP: /v1/auth/*
        REDEEM_LIMIT: RateLimit; // 10 requests / 60 s per client IP: code redemption and invite accept
        PUBLIC_URL: string; // https://scorebug.live
        APP_AUTH_REDIRECT: string; // scorebug://auth
        ADMIN_EMAILS: string;
        GOOGLE_CLIENT_ID: string;
        GOOGLE_CLIENT_SECRET: string;
        SERVER_SECRET: string; // >= 32 chars; HMAC key for state, route codes and match credentials
    }
    // app.ts
    export type WorkerDeps = { env: Env; google: GoogleOAuth; now?: () => number };
    export function createWorkerApp(deps: WorkerDeps): Hono<{ Bindings: Env }>;
    ```
- `wrangler.jsonc`:
    - `name: "scorebug"`, `main: "src/worker/index.ts"`,
      `compatibility_flags: ["nodejs_compat"]`;
    - `d1_databases: [{ binding: "DB", database_name: "scorebug", migrations_dir: "migrations" }]`;
    - the Durable Object `TEAM` → class `TeamObject` with SQLite storage;
    - the two `ratelimits` bindings above;
    - `routes: [{ pattern: "scorebug.live", custom_domain: true }]`;
    - the public vars.
- Scripts:
    - `"test:worker": "vitest run --config vitest.worker.config.ts"`;
    - `"typecheck"` runs both `tsc -p tsconfig.json --noEmit` and
      `tsc -p tsconfig.worker.json --noEmit`.
- `migrations/0001_initial.sql` creates:
    - `people(id TEXT PRIMARY KEY, google_sub TEXT NOT NULL UNIQUE, email TEXT NOT NULL, name TEXT, picture TEXT, created_at INTEGER NOT NULL, last_seen_at INTEGER NOT NULL)`
    - `beta_access(email TEXT PRIMARY KEY, can_create_teams INTEGER NOT NULL DEFAULT 1, added_by TEXT NOT NULL, added_at INTEGER NOT NULL)`
    - `sessions(token_hash TEXT PRIMARY KEY, person_id TEXT NOT NULL REFERENCES people(id), device_name TEXT, created_at INTEGER NOT NULL, last_used_at INTEGER NOT NULL, revoked_at INTEGER)`
    - `auth_tickets(ticket_hash TEXT PRIMARY KEY, challenge TEXT NOT NULL, person_id TEXT NOT NULL REFERENCES people(id), expires_at INTEGER NOT NULL, used_at INTEGER)`
    - `teams(id TEXT PRIMARY KEY, name TEXT NOT NULL, short_name TEXT NOT NULL, color TEXT NOT NULL, created_by TEXT NOT NULL REFERENCES people(id), created_at INTEGER NOT NULL)`
    - `memberships(team_id TEXT NOT NULL REFERENCES teams(id), person_id TEXT NOT NULL REFERENCES people(id), role TEXT NOT NULL CHECK(role IN ('owner','member')), created_at INTEGER NOT NULL, PRIMARY KEY(team_id, person_id))`
    - `team_invites(id TEXT PRIMARY KEY, team_id TEXT NOT NULL REFERENCES teams(id), code_hash TEXT NOT NULL UNIQUE, email TEXT, created_by TEXT NOT NULL, created_at INTEGER NOT NULL, expires_at INTEGER NOT NULL, revoked_at INTEGER)`
    - `match_index(game_id TEXT PRIMARY KEY, team_id TEXT NOT NULL REFERENCES teams(id), created_at INTEGER NOT NULL)`
    - `match_codes(code_hash TEXT PRIMARY KEY, invite_id TEXT NOT NULL UNIQUE, team_id TEXT NOT NULL, game_id TEXT NOT NULL, expires_at INTEGER NOT NULL)`

- [ ] **Step 1: Write the failing test** `test-worker/health.test.ts`:
      `SELF.fetch('https://scorebug.live/healthz')` returns 200
      `{ ok: true }`, and `env.DB` has the tables above (query
      `sqlite_master`). Migrations are applied in the pool config with
      `readD1Migrations` and `applyD1Migrations`, per the package README.
- [ ] **Step 2: Run** `pnpm --filter @scorebug/control-plane test:worker`
      Expected: FAIL. There's no Worker entry yet.
- [ ] **Step 3: Implement** the scaffold. `index.ts` builds
      `createWorkerApp({ env, google: realGoogle(env) })` per request and
      re-exports `TeamObject` as an empty Durable Object class until Task 5.
- [ ] **Step 4: Run** `pnpm --filter @scorebug/control-plane test:worker && pnpm --filter @scorebug/control-plane typecheck`
      Expected: PASS.
- [ ] **Step 5: Commit** `feat(worker): scaffold Worker, D1 schema and test pool`

### Task 3: Google sign-in, sessions, private beta

**Files:**

- Create: `src/worker/google.ts`, `src/worker/state.ts`, `src/worker/directory.ts` (people, beta, sessions and tickets parts), `src/worker/auth-routes.ts`, `test-worker/auth.test.ts`, `test-worker/fake-google.ts`
- Modify: `src/worker/app.ts` (mount routes and the session middleware)

**Interfaces:**

- Produces:
    ```ts
    // google.ts
    export type GoogleIdentity = {
        sub: string;
        email: string;
        emailVerified: boolean;
        name: string | null;
        picture: string | null;
    };
    export type GoogleGrant = {
        identity: GoogleIdentity;
        refreshToken: string | null;
        scopes: string[];
    };
    export interface GoogleOAuth {
        authorizeUrl(p: {
            state: string;
            scopes: string[];
            redirectUri: string;
            prompt: 'select_account' | 'consent';
            loginHint?: string;
        }): string;
        exchange(code: string, redirectUri: string): Promise<GoogleGrant>; // throws GoogleOAuthError
    }
    export function realGoogle(env: Env): GoogleOAuth; // token endpoint POST; id_token claims checked for aud, iss, exp (no JWKS: received directly from Google over TLS)
    // state.ts
    export type OAuthState = {
        challenge: string;
        invite: string | null;
        purpose: 'app' | 'admin';
        exp: number;
    };
    export function signState(secret: string, s: OAuthState): string;
    export function verifyState(secret: string, raw: string, now: number): OAuthState | null;
    export function routeCodeHash(secret: string, code: string): string; // HMAC-SHA256 hex over ['route-code', normalizeInviteCode(code)]
    // auth-routes.ts: session middleware sets c.var.person
    export type Person = { id: string; email: string; name: string | null; picture: string | null };
    export function requirePerson(): MiddlewareHandler<{
        Bindings: Env;
        Variables: { person: Person };
    }>;
    ```
- **Routes:**
    - `GET /v1/auth/google/start?challenge=<43-char base64url>&invite=<code?>`
      → 302 to Google, with `prompt=select_account`, the scopes from Global
      Constraints, and the redirect URI `${PUBLIC_URL}/v1/auth/google/callback`.
    - `GET /v1/auth/google/callback?code&state` or `?error&state` → 302 to
      `${APP_AUTH_REDIRECT}?status=ok&ticket=<t>`. Other statuses:
      `not_in_beta`, `cancelled` and `error`. With purpose `admin`, it
      redirects to `/admin` with a cookie instead (Task 6).
    - `POST /v1/auth/session {ticket, verifier, deviceName}` → 200
      `{ token, person, serverTime }`. It returns 401 `ticket_invalid` when a
      ticket is expired, used, or its `sha256(verifier)` doesn't match.
    - `GET /v1/me` → `{ person, canCreateTeams, teams: { id, name, shortName, color, role }[] }`.
    - `DELETE /v1/auth/session` → 204, and the token stops working.
- **Access rule:** a verified identity gets in if any of these hold:
    - its normalized email is in `beta_access`;
    - it already has a membership;
    - it has an unexpired, unrevoked team invite bound to its email;
    - `state.invite` is a valid team invite it may accept.

    On a successful sign-in, upsert the person, then accept the `state.invite`
    and every email-bound invite. Otherwise, store nothing and redirect with
    `not_in_beta`. `canCreateTeams` is true only for a `beta_access` row with
    `can_create_teams = 1`.

- [ ] **Step 1: Write the failing tests** in `test-worker/auth.test.ts`,
      using `fake-google.ts`, an in-memory `GoogleOAuth` whose `exchange(code)`
      returns a scripted grant:
    - `full sign-in issues a session`: allowlisted email, then start, then
      callback 302 with `status=ok`, then `POST /v1/auth/session` → 200, then
      `GET /v1/me` → 200 with `teams: []`.
    - `allowlist matches case-insensitively`: allowlist
      `" JD.Conley@Gmail.com "`, Google returns `jd.conley@gmail.com` →
      `status=ok`.
    - `rejects unverified email`: `emailVerified: false`, allowlisted →
      `status=not_in_beta`, and the `people` table stays empty.
    - `not in beta stores nothing` → `status=not_in_beta`, and `people` stays
      empty.
    - `cancelled consent redirects to app`: callback with
      `error=access_denied` → 302 to `scorebug://auth?status=cancelled`.
    - `tampered state is rejected` → `status=error`.
    - `ticket is single use`: a second `POST /v1/auth/session` with the same
      ticket → 401 `ticket_invalid`.
    - `ticket needs the matching verifier` → 401.
    - `ticket expires after 2 minutes`: `now` advanced 121 s → 401.
    - `sign out revokes the token`: `DELETE` then `GET /v1/me` → 401.
- [ ] **Step 2: Run** `pnpm --filter @scorebug/control-plane test:worker -- auth`
      Expected: FAIL.
- [ ] **Step 3: Implement** the files above. Rate-limit `/v1/auth/*` with
      `AUTH_LIMIT`, keyed by `cf-connecting-ip`, returning 429 `rate_limited`.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** `feat(worker): Google sign-in, sessions and private beta`

### Task 4: Teams, members, team invites

**Files:**

- Create: `src/worker/team-routes.ts`, `test-worker/teams.test.ts`
- Modify: `src/worker/directory.ts` (team, membership and invite queries), `src/worker/app.ts`

**Interfaces:**

- Consumes: `requirePerson()`, `Person`, and `routeCodeHash` (reused as the
  team invite `code_hash` with purpose `'team-invite'`: HMAC over
  `['team-invite', normalizeInviteCode(code)]`).
- Produces:
    ```ts
    export type Team = {
        id: string;
        name: string;
        shortName: string;
        color: string;
        createdAt: string;
    };
    export type TeamRole = 'owner' | 'member';
    export function requireMember(role?: 'owner'): MiddlewareHandler; // 404 team_not_found for non-members, 403 owner_required
    ```
    The `name`, `shortName` and `color` validation reuses the `team` zod
    schema rules in `src/routes/matches.ts`: name 1–80, shortName ≤8 code
    points defaulting through `defaultShortName`, color `#RRGGBB`.
- **Routes:**
    - `POST /v1/teams {name, shortName?, color?}` (color defaults to `#2563EB`) → 201 `{ team, role: 'owner' }`,
      or 403 `cannot_create_teams`.
    - `GET /v1/teams/:teamId` → `{ team, role, members: { personId, name, email, role }[], invites? }`.
      `invites` is for owners only and never includes codes.
    - `PATCH /v1/teams/:teamId {name?, shortName?, color?}` (owner) → `{ team }`.
    - `POST /v1/teams/:teamId/invites {email?, expiresInDays?}` (owner) → 201
      `{ invite, code, link }`, where `link = ${PUBLIC_URL}/invite/${code}`.
    - `DELETE /v1/teams/:teamId/invites/:inviteId` (owner) → `{ invite }` with
      `revokedAt` set.
    - `POST /v1/team-invites/accept {code}` → `{ team, role: 'member' }`. It
      returns 404 `invite_invalid` for an unknown, expired or revoked invite,
      and 403 `invite_email_mismatch`. It's idempotent for existing members,
      and rate-limited by `REDEEM_LIMIT`.
    - `DELETE /v1/teams/:teamId/members/:personId`: an owner removes someone,
      or a person removes themselves. It returns 409 `last_owner` if it would
      leave the team with no owner.

- [ ] **Step 1: Write the failing tests** in `test-worker/teams.test.ts`:
    - `owner creates a team`.
    - `person without can_create_teams cannot create`.
    - `non-member gets 404 for a team`.
    - `member cannot invite` → 403.
    - `link invite lets an unlisted person in`: start with `invite=<code>`,
      then callback `status=ok`, then `/v1/me` lists the team as `member`, and
      `canCreateTeams` is false.
    - `email invite auto-accepts on first sign-in`.
    - `email invite rejects another email` → 403 `invite_email_mismatch`.
    - `revoked invite is invalid`.
    - `last owner cannot leave`.
    - `member can leave`.
    - `one person on two teams sees both in /v1/me`.
- [ ] **Step 2: Run** `pnpm --filter @scorebug/control-plane test:worker -- teams`
      Expected: FAIL.
- [ ] **Step 3: Implement** the files above.
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** `feat(worker): teams, members and team invites`

### Task 5: `TeamObject` and match forwarding

**Files:**

- Create: `src/worker/team-object.ts`, `src/worker/match-forwarding.ts`, `test-worker/matches.test.ts`
- Modify:
    - `src/routes/matches.ts`: `matchesRoutes(config, store, access, relayLifecycle?, observations?)`;
    - `src/routes/account.ts`: `inviteRoutes(config, store, access)`;
    - `src/app.ts`: passes `ownerAccess(config, store)`, so Node behavior is
      unchanged;
    - `src/worker/app.ts`.

**Interfaces:**

- Produces:
    ```ts
    // routes/matches.ts
    export type MatchAccess = {
        bootstrap: MiddlewareHandler; // guards create / active / join; 401 if absent
        issuer(c: Context): string | undefined; // invite issuer for owner-level callers, else undefined
        joinLink(code: string): string;
        onInvite?: {
            issued(i: {
                inviteId: string;
                code: string;
                gameId: string;
                expiresAt: string;
            }): Promise<void>;
            revoked(i: { inviteId: string; gameId: string }): Promise<void>;
        };
    };
    export function ownerAccess(config: Config, store: MatchStore): MatchAccess; // today's device-token behavior and scorebug:// links
    // team-object.ts
    export class TeamObject extends DurableObject<Env> {} // fetch(): matchesRoutes over new MatchStore(durableObjectSql(ctx.storage), env.SERVER_SECRET)
    ```
- **Trusted member access in `TeamObject`:**
    - `bootstrap` accepts only a request carrying
      `x-scorebug-member: <personId>`, and sets the device owner as
      `member:<personId>`.
    - `issuer` returns `member:<personId>` from that header. A request without
      it falls back to the match `capture` credential, as today.
    - `joinLink(code)` returns `${PUBLIC_URL}/join/${code}`.
    - `onInvite.issued` inserts a `match_codes` row with
      `code_hash = routeCodeHash(SERVER_SECRET, code)`, and `revoked` deletes it.
- **Worker forwarding** (`match-forwarding.ts`). The team ID is the
  Durable Object name (`env.TEAM.getByName(teamId)`).
    - `POST|GET /v1/teams/:teamId/matches[/*]` →
      `requireMember()`, then strip any incoming `x-scorebug-member`, set it to
      the person, rewrite the path to `/v1/matches[/*]`, and forward.
    - Before forwarding a create, insert `match_index(game_id, team_id)`:
        - an existing row for the same team means continue (idempotent retry);
        - a row for another team means 409 `match_id_taken`.
    - `/v1/matches/:id` and `/v1/matches/:id/*` (match-token routes): look up
      `match_index`, return 404 `match_not_found` if it's missing, otherwise
      forward unchanged with `x-scorebug-member` removed.
    - `POST /v1/invites/redeem`: `REDEEM_LIMIT`, then `routeCodeHash` and
      look up an unexpired `match_codes` row. Return 404 `invite_invalid` if
      there's none, otherwise forward to the team object.
- `/media` routes are mounted with no relay, so broadcast start returns 503
  `relay_not_configured` until plan 3. Recording reports work.

- [ ] **Step 1: Write the failing tests** in `test-worker/matches.test.ts`,
      using the protocol fixtures in `packages/protocol` for request bodies:
    - `member creates and scores a match`: create → 201 with a `score`
      credential; `POST /v1/matches/:id/commands` `award_point` → 200 with
      revision 1.
    - `second concurrent create sees active match`: two creates via
      `Promise.all` → one 201, and one 409 `match_in_flight` carrying the
      active snapshot.
    - `match id taken by another team`.
    - `non-member cannot see a team's active match` → 404.
    - `spoofed member header is overwritten`: a non-member sends
      `x-scorebug-member` set to a member's ID → still 404.
    - `teams are isolated`: team A's match token gets 401 on team B's match ID
      path.
    - `match join code works without an account`: an owner mints an invite,
      `POST /v1/invites/redeem` with no session → 200 with a `score`
      credential, and the link starts with `https://scorebug.live/join/`.
    - `revoked match code stops routing` → 404 `invite_invalid`.
    - `recording report is accepted` on `/v1/matches/:id/media/recording` with
      a `capture` credential from `/v1/teams/:teamId/matches/:id/join`.
- [ ] **Step 2: Run** `pnpm --filter @scorebug/control-plane test:worker -- matches` (FAIL), and
      `pnpm --filter @scorebug/control-plane test` (the Node suites must stay
      green after the `MatchAccess` refactor).
- [ ] **Step 3: Implement** the files above.
- [ ] **Step 4: Run** both commands. Expected: PASS.
- [ ] **Step 5: Commit** `feat(worker): team Durable Object serves matches and scoring`

### Task 6: Admin page for the beta list

**Files:**

- Create: `src/worker/admin-page.ts`, `test-worker/admin.test.ts`
- Modify: `src/worker/auth-routes.ts` (purpose `admin`: callback sets the cookie), `src/worker/app.ts`

**Interfaces:**

- **Routes:**
    - `GET /admin`: without a valid `sb_admin` cookie, 302 to
      `/v1/auth/google/start?purpose=admin&challenge=<server-generated>`.
    - **Cookie:** the callback for purpose `admin` sets
      `sb_admin=<session token>; Secure; HttpOnly; SameSite=Strict; Path=/admin; Max-Age=43200`,
      but only when the person's email is in `ADMIN_EMAILS`. Otherwise it
      returns 403. The session row gets `device_name = 'admin web'`.
    - `GET /admin` (signed in) → an HTML page that lists `beta_access`
      (email, can create teams, added at) and every team with member counts.
      It has a form to add an email with a "can create teams" checkbox, and a
      remove button per row. Use server-rendered `hono/html` with no client
      JS.
    - `POST /admin/beta` (form: `email`, `canCreateTeams`) and
      `POST /admin/beta/remove` (form: `email`). Both require the cookie and
      `Origin === PUBLIC_URL`, then 303 to `/admin`.
- Removing an email blocks future sign-ins only when the person has no
  memberships. Existing sessions keep working. The page says so beside the
  remove button.

- [ ] **Step 1: Write the failing tests** in `test-worker/admin.test.ts`:
    - `non-admin is refused`;
    - `admin adds an email`: POST, then the email appears in the page HTML,
      and that person's sign-in now gets `status=ok`;
    - `cross-origin post is refused` → 403;
    - `cookie is scoped to /admin`: the `Set-Cookie` has `Path=/admin` and
      `HttpOnly`.
- [ ] **Step 2: Run** `pnpm --filter @scorebug/control-plane test:worker -- admin`
      Expected: FAIL.
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run** the same command. Expected: PASS.
- [ ] **Step 5: Commit** `feat(worker): admin page for the private beta list`

### Task 7: Production setup and deploy on merge

**Files:**

- Create: `.github/workflows/deploy.yml`
- Modify: `apps/control-plane/wrangler.jsonc` (`database_id` of the real D1 database), `docs/development.md` (a "Worker" section: `wrangler dev`, the secrets list, `pnpm test:worker`)

**Interfaces:**

- `deploy.yml`:
    - **When:** on `push` to `main` with changes under `apps/control-plane/**`,
      `packages/protocol/**` or the workflow itself.
    - **Steps:** checkout, pnpm install, build the protocol, then
      `wrangler d1 migrations apply scorebug --remote` and `wrangler deploy`
      from `apps/control-plane`.
    - **Secrets:** GitHub `CLOUDFLARE_API_TOKEN` and `CLOUDFLARE_ACCOUNT_ID`.
    - **Concurrency:** group `deploy-production`, so a newer push cancels an
      older one.

- [ ] **Step 1: JD creates the Google OAuth client**
    - Google Cloud project "Scorebug" under Conley Chaos LLC.
    - OAuth consent screen: External, Testing, with JD's address as a test
      user.
    - A Web application client with the authorized redirect URI
      `https://scorebug.live/v1/auth/google/callback`.
- [ ] **Step 2: Create the D1 database**
      With JD's OK, Claude runs `wrangler d1 create scorebug` and writes the
      printed `database_id` into `wrangler.jsonc`.
- [ ] **Step 3: JD sets secrets** (values never pass through chat):
    ```bash
    cd apps/control-plane
    wrangler secret put GOOGLE_CLIENT_ID
    wrangler secret put GOOGLE_CLIENT_SECRET
    wrangler secret put SERVER_SECRET
    ```
    Then in GitHub repo settings, JD adds `CLOUDFLARE_API_TOKEN` (Workers
    Scripts:Edit, D1:Edit, Workers Routes:Edit, for the scorebug.live zone) and
    `CLOUDFLARE_ACCOUNT_ID`.
- [ ] **Step 4: Write `deploy.yml`** and the docs section. Commit:
      `ci: deploy the Worker to scorebug.live on merge`.
- [ ] **Step 5: Verify after the PR merges**
    - Expected: the deploy job is green, and `curl -s https://scorebug.live/healthz`
      prints `{"ok":true}`.
    - JD signs in at `https://scorebug.live/admin` and sees an empty beta
      list.
    - JD adds his own email, with "can create teams" checked.

---

## Later plans (written after this one lands and the spike reports)

3. **YouTube channels, Stream and Go Live:** channel connections with the
   `youtube` scope and incremental consent, a per-team channel, the Stream
   adapter, the container image, the match lifecycle and teardown guards, and
   the beta concurrency cap.
4. **Web pages and Google verification:** the home page, privacy, terms,
   invite and join landing pages, Search Console, the demo video, and the
   submission.
5. **iPhone app:** sign in, teams on Home, the team screen, invite and join
   links, connecting a channel, the fixed server, and removing QR and setup.
6. **Remove self-hosting:** infra, the Node server entry, setup links and
   devices, docs and CI. Rewrite the field test.
