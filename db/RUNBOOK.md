# Supabase → Neon: the runbook

Step-by-step commands for the migration. The reasoning, the decisions and the
phase plan live in the **"neon-migration-guide"** doc in this project's Claude
project; this file is what you actually run, in order.

Everything below has been replayed against a disposable Postgres 16 standing in
for Neon, as a real non-superuser role with RLS enforced. Where a step has not
been verified against Neon itself, it says so.

Nothing in Phases 0–5 touches the live Supabase project. Phase 6 is the only one
that does.

---

## Before you start: four things to check, in about five minutes

Each of these can change the plan, and each is cheap to answer now and expensive
to discover halfway through.

**1. Can you read the password hashes out of Supabase?** In the Supabase SQL
editor:

```sql
select count(*) as accounts,
       count(encrypted_password) as with_hash,
       left(min(encrypted_password), 4) as hash_prefix
  from auth.users;
```

A `$2a$` or `$2b$` prefix is bcrypt, which `bcryptjs` verifies directly, so
nobody has to change their password. If this errors with permission denied, that
is not a blocker: the app already has a first-login password flow
(`profiles.password_set = false` → the worker sets their own password), so the
fallback is to import accounts with `password_set = false` and let everyone set
a password once. No code changes either way.

**2. Does your Neon role have the attributes the plan assumes?** On Neon:

```sql
select current_user, rolcreaterole, rolbypassrls, rolsuper
  from pg_roles where rolname = current_user;
```

`rolcreaterole` must be true. `rolbypassrls` is a nice-to-have only — the design
deliberately does not depend on it (see Phase 1).

**3. Does `SET LOCAL` survive Neon's pooler?** This is the single property the
whole security model rests on. Against the **pooled** connection string:

```sql
begin;
select set_config('app.current_profile_id', 'aaaaaaaa-0000-0000-0000-000000000001', true);
select current_setting('app.current_profile_id', true) as inside_txn;
commit;
select coalesce(nullif(current_setting('app.current_profile_id', true), ''), '(cleared)') as after_commit;
```

You need `inside_txn` to show the id and `after_commit` to show `(cleared)`.
Neon's pooler is PgBouncer in transaction mode, and its docs list session-level
`SET`/`RESET` as unsupported while transaction-scoped settings are fine — this
confirms it for your project rather than taking the docs' word for it.

**4. How big is the data?** Decides whether Phase 6's window is two minutes or
twenty:

```sql
select relname, n_live_tup,
       pg_size_pretty(pg_total_relation_size(relid)) as size
  from pg_stat_user_tables
 where schemaname = 'public'
 order by pg_total_relation_size(relid) desc;
```

---

## Phase 0 — a Neon project, and the schema on it

### 0.1 Drop migration 0044's dead weight, on Supabase, first

Migration 0044 added PostGIS region boundaries for the Mapbox work that was
later cancelled. Nothing in the application references `regions.boundary`,
`orders.customer_lat/lng/customer_point` or `region_for_point()` — the maps are
drawn client-side with Leaflet. PostGIS itself brings about 590 functions, the
`spatial_ref_sys` table (the one table in `public` with no RLS) and two views.

Dropping it before the migration means Neon never needs the extension at all,
and the migration has that much less surface to verify. Run on Supabase:

```sql
begin;
drop function if exists public.region_for_point(double precision, double precision);
drop index if exists public.orders_customer_point_idx;
drop index if exists public.regions_boundary_idx;
alter table public.orders  drop column if exists customer_point;
alter table public.orders  drop column if exists customer_lat;
alter table public.orders  drop column if exists customer_lng;
alter table public.regions drop column if exists boundary;
commit;
-- separately, once the above is committed and nothing complains:
drop extension if exists postgis;
```

Then `npm run typecheck && npm run test` to confirm nothing referenced them.
Keep this as `db/migrations/0051_drop_region_boundaries.sql` so both
databases stay in step.

If you would rather keep boundaries, skip this and uncomment the `create
extension postgis` line in `db/neon/0000_prelude.sql` instead — PostGIS
is supported on Neon (3.5.7 on PG17).

### 0.2 Create the Neon project

Pick the region closest to your Vercel deployment; a cross-continent hop adds
latency to every query and this app is query-chatty on the order pages. Take
both connection strings — pooled and direct. Scale-to-zero can stay on.

### 0.3 Apply the schema

Use the **direct** (unpooled) connection string for all of this — schema
migrations need session-level features the pooler does not allow.

```bash
export NEON_DIRECT='postgresql://...@...neon.tech/neondb?sslmode=require'

# 1. the prelude: the Supabase-shaped pieces the chain assumes exist
psql "$NEON_DIRECT" -v ON_ERROR_STOP=1 -f db/neon/0000_prelude.sql

# 2. every migration in db/migrations/, in order, UNMODIFIED —
#    substituting the one pg_net-free variant for 0041
for f in db/migrations/*.sql; do
  case "$(basename "$f")" in
    0041_*) f=db/neon/0041_push_dispatch_trigger.neon.sql ;;
    0044_*) continue ;;   # dropped in 0.1; skip if you kept it
  esac
  echo "-- $f"
  psql "$NEON_DIRECT" -v ON_ERROR_STOP=1 -f "$f" || break
done

# 3. the shim: auth.uid(), grants, roles
psql "$NEON_DIRECT" -v ON_ERROR_STOP=1 -f db/neon/0001_auth_shim.sql
```

Why a prelude rather than editing the chain: `db/migrations/` stays the
single source of truth for both databases, so a migration written next month
does not have to be written twice and cannot drift. The prelude supplies the
`auth` schema, the `extensions` schema, PostgREST's `anon`/`authenticated`/
`service_role` roles (the chain issues 90 `grant … to authenticated` and 10 `to
anon`, and the first one aborts without them), and a `net.http_post()` with
pg_net's exact signature that writes to an outbox table instead of opening a
socket. `create extension pg_net` is the one thing that cannot be faked —
Postgres wants a control file on the server's filesystem — so exactly one file
is substituted, and `diff` it against the original: the only change is that line.

### 0.4 Set the role passwords, out of band

Never in a committed file.

```sql
alter role app_user  with login password '<from your secrets manager>';
alter role app_admin with login password '<a different one>';
```

### 0.4b Test as the role that will actually run it

Every local test of these files ran as the Postgres superuser, and that hid a
failure that stopped a real setup dead: the shim's `DROP OWNED BY anon`
needs superuser or membership in the target role, and Neon's owner role has
neither. It aborted with `permission denied to drop objects`, which took the
rest of the file with it — the whole auth layer — and left a database that
looked fine by table count.

So when testing this chain locally, apply it as a non-superuser role with
CREATEROLE, not as `postgres`:

```sql
create role neon_superuser nologin createrole createdb;
create role neondb_owner login createrole createdb password '...' in role neon_superuser;
create database neondb owner neondb_owner;
```

This is the second time that blind spot has cost something here. The first
was `ALTER DATABASE SET` on Supabase, which passed locally as superuser and
failed in production with `42501`. A privileged test proves the SQL is valid,
not that it is permitted.

### 0.5 Exit criteria

```sql
-- expect: 23 policies, 13 RLS tables, 67 security-definer functions,
-- all of them pinning search_path
select (select count(*) from pg_policies where schemaname='public') as policies,
       (select count(*) from pg_class c join pg_namespace n on n.oid=c.relnamespace
         where n.nspname='public' and c.relrowsecurity) as rls_tables,
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.prosecdef) as secdef,
       (select count(*) from pg_proc p join pg_namespace n on n.oid=p.pronamespace
         where n.nspname='public' and p.prosecdef
           and (p.proconfig is null or not exists (
                 select 1 from unnest(p.proconfig) c where c like 'search_path=%'))
       ) as secdef_missing_search_path;

-- expect: anon and service_role gone, authenticated present but powerless
select rolname, rolcanlogin from pg_roles
 where rolname in ('anon','authenticated','service_role','app_user','app_admin')
 order by rolname;
```

`secdef_missing_search_path` must be 0. A `SECURITY DEFINER` function without a
pinned `search_path` is a privilege-escalation hole; all 67 pin it today and that
must stay true.

---

## Phase 1 — the shim (already written; re-read what it now does)

`db/neon/0001_auth_shim.sql` replaces `auth.uid()` with a function that
reads `app.current_profile_id` — a transaction-local setting the app sets — rather
than a GoTrue JWT claim. That is the single biggest risk-reducer available here:
`auth.uid()` is called **108 times across 28 migration files**, inside RLS
policies and inside `SECURITY DEFINER` bodies alike, and none of those call sites
change.

Three things in it are worth knowing because each one was a bug found by
replaying the real chain rather than reading it:

**It used to abort on line 162.** It granted `select` on `factory_orders_view`,
which migration 0038 dropped when factories stopped being accounts. The file
could not be applied to any schema past 0038 at all.

**Six tables added by migrations 0033–0050 had no grants.** Three of them —
`factories`, `manager_factories`, `push_subscriptions` — are read directly by
application code, so the app would have come up after cutover and failed with
`permission denied for table factories` on the team page, the order page and
order creation. The other three — `order_delivery_codes`, `order_pickup_codes`,
`app_settings` — are *correctly* left without grants: they have RLS on with zero
policies, so they are reachable only through a `SECURITY DEFINER` function that
decides what to reveal. `push_outbox` joins them for the same reason.

**Four policies are scoped `to authenticated`, not `to public`.** 20 of the 23
are `to public` and apply to whatever role connects; `factories_select`,
`manager_factories_select`, `push_subscriptions_select_own` and
`push_subscriptions_delete_own` are not. A policy scoped to a role you are not a
member of simply does not apply, and with RLS on and no applicable policy the
answer is **zero rows — no error, nothing in a log**. After cutover the team page
would have listed no factories, order creation could not have picked one (and a
factory is mandatory), and the push card would have shown no devices. It would
have looked exactly like the data had not copied. The shim therefore keeps
`authenticated` as a NOLOGIN role stripped of every privilege and makes
`app_user` a member of it, purely so those four policies apply. Membership, not
privilege — and it means a policy written `to authenticated` next month, which is
the normal thing to write against Supabase, keeps working here without anyone
remembering this.

**On the service-role replacement.** Supabase's `createAdminClient()` bypasses
RLS for the pre-login phone lookup. The plan originally called for an `app_admin`
role with `BYPASSRLS`. Neon's owner role is a member of `neon_superuser`, which
holds `BYPASSRLS`, but Postgres role attributes are not inherited through
membership and from PG16 a `CREATEROLE` role may only grant `BYPASSRLS` if it
holds it itself — so that `CREATE ROLE` may be refused. The shim now catches that
and carries on, because the better design does not need it: the pre-login lookups
go through a `SECURITY DEFINER` function owned by the tables' owner, which sees
past RLS for the duration of the call and returns only what it chooses. That is
strictly less privilege than a role that bypasses RLS on everything, so prefer it
even where `BYPASSRLS` is available.

### What was verified, as `app_user` (not superuser, not `BYPASSRLS`)

Driver A sees only their own order; driver B on the same connection sees only
theirs; the owner and the moderator see both; a transaction with no identity set
sees zero rows in `orders` and zero in `profiles`; the deny-all tables raise
`42501` even for the owner; and a real order created through the real
`moderator_create_order` RPC behaves identically. A notification that should push
lands in `push_outbox` with the same URL, the same `{"notification_id": …}` body,
the same secret header and the same 5000 ms timeout that pg_net would have sent.

And the reason `SET LOCAL` is mandatory rather than stylistic, demonstrated
rather than asserted: a session-level `SET app.current_profile_id` **leaked into
the next transaction on the same connection**, which on a pooled connection is
one request answering with another user's identity. Every request must do its
`set_config(…, true)` and its queries inside one `BEGIN`/`COMMIT` on one
checked-out client.

---

## Phase 2 — the auth layer

Build it standalone, against Neon, with synthetic accounts. Production untouched.

Neon's own auth product is still not an option, re-checked in October 2026: the
phone-number plugin is "sign-in only", needs an SMS provider and a `send.otp`
webhook, and has no phone+password path at all. Every account in this app is
phone + password with no email. So: a small custom layer.

```
src/lib/db/pool.ts              pg Pool on the POOLED connection string
src/lib/db/with-user-context.ts the one function every request goes through
src/lib/db/sql.ts               tagged-template query helper, parameterised only
src/lib/auth/session.ts         iron-session sealed cookie
src/lib/auth/password.ts        bcryptjs hash/verify
```

`withUserContext` is the whole security model in one function, and the only place
allowed to open a transaction:

```ts
export async function withUserContext<T>(
  profileId: string | null,
  fn: (q: Querier) => Promise<T>,
): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query("begin");
    // transaction-scoped, third arg true — never a session-level SET
    await client.query("select set_config('app.current_profile_id', $1, true)", [
      profileId ?? "",
    ]);
    const result = await fn(makeQuerier(client));
    await client.query("commit");
    return result;
  } catch (e) {
    await client.query("rollback");
    throw e;
  } finally {
    client.release();
  }
}
```

Rules that have to hold, because the isolation property depends on them: one
`withUserContext` per request; never a query outside one; never `pool.query()`
directly; `profileId` comes only from the verified session cookie, never from
anything a client sent. A lint rule banning `pool.query` outside `src/lib/db/`
is worth the ten minutes.

`pg` is currently a **devDependency** (`^8.23.0`, used by
a dev-only script). Move it to `dependencies` or the production build
fails.

A short Node script against the pooled connection string is the best starting
point for this file — one already
does `begin` / `set local role` / `set_config('request.jwt.claim.sub', …)`
against a real connection with RLS enforced.

Password hashes carry over as-is if step 1 of the pre-flight said bcrypt.
`bcryptjs` verifies `$2a$` and `$2b$`, so nobody has to change a password.

### The one architectural change: `src/proxy.ts`

Today the proxy calls `auth.getUser()` (a network round trip to GoTrue) and then
queries `profiles` — **on every request** — and forwards the verified row in the
`x-verified-profile` header. `pg` cannot run there: the proxy is on the Edge
runtime and cannot declare otherwise.

Replace it with a sealed session cookie the proxy verifies with Web Crypto and
no database hit at all: the cookie carries the profile id, role and `is_active`,
the proxy verifies the signature and forwards the same header, and
`src/lib/auth.ts` keeps reading that header exactly as it does now. Keep
`request.headers.delete(VERIFIED_PROFILE_HEADER)` as the first thing the proxy
does — a client-supplied copy of that header is the one input that would
otherwise forge an identity.

This is faster than today (no GoTrue round trip, no `profiles` query per
request), with one tradeoff to name: deactivating an account no longer takes
effect on the next request, but on the next cookie refresh. Two mitigations,
both cheap — keep the cookie short (15 minutes, rolling, inside a 14-day
absolute expiry) so a deactivation lands within a quarter hour, and have the
`requireRole()` path re-check `is_active` on anything that matters. The database
is the real boundary regardless: every RPC re-checks the caller's role and
`is_active` server-side, which is what actually stops a deactivated session, and
that does not change.

---

## Phase 3 — the data layer

**42 `.from()` call sites across 12 files** and **46 `.rpc()` call sites across 6
files, covering 44 distinct functions.** The RPCs are the easy half: the business
logic is already in Postgres and the chain replays, so each one becomes a
`select * from fn($1, $2, …)` inside `withUserContext`. The `.from()` calls are
ordinary SQL.

Do not reimplement PostgREST's builder. A thin hand-written query per call site
is clearer and leaves less room to get a filter subtly wrong. Two details carried
over from the existing code, both deliberate and both easy to lose in a rewrite:
`listAllOrdersForExport` pages in 1000-row batches because PostgREST capped a
request at 1000 rows — a plain `pg` query has no such cap, so it becomes one
query, but keep a `LIMIT` on it; and `getOrderMessages` orders newest-first with
`LIMIT 200` and then reverses, which keeps the *most recent* 200 rather than the
oldest, so do not "simplify" it to ascending.

Suggested order, so nothing is half-migrated for long: `src/lib/db/*` first, then
`src/lib/auth/*` and the three login/bootstrap Server Actions, then
`src/lib/data/*` (4 files), then `src/lib/actions/*` (7 files), then the proxy,
then delete `src/lib/supabase/`. The two browser-side consumers
(`sign-out-button.tsx`, `idle-logout-watcher.tsx`) only call `auth.signOut()` and
become a `POST` to a sign-out route.

The 11 admin-client sites mostly disappear: they exist because login is
phone-based while GoTrue is email-based, and that indirection goes away once you
own the accounts table. The ones that remain — the pre-login phone lookup, and
the push dispatch route's cross-user read — become narrow `SECURITY DEFINER`
functions.

---

## Phase 4 — push, without pg_net

Confirmed against Neon's extension list: `pg_net` is not available, nor is
`http`, nor `pgsodium`. And Neon's Function Triggers fire on a schedule or on
object-storage events — **not** on a row change — so there is no drop-in webhook
either.

`0000_prelude.sql` already handles the database side: `net.http_post()` has
pg_net's exact named-parameter signature as migrations 0041 and 0042 call it, and
writes the request to `public.push_outbox` instead of sending it. Migrations
0041/0042 are unmodified apart from the one commented-out `create extension`
line. Something now has to drain that table, and the recommended shape is both
of these together:

**Immediate, for latency.** After a Server Action's RPC returns, fire the
dispatch directly — `void fetch('/api/push/dispatch', …)`, not awaited, so push
can never delay or fail an order. Same route, same `x-push-secret` header, same
`{notification_id}` body; the route itself needs no changes at all.

**A sweep, for reliability.** A Neon scheduled Function (or a Vercel cron) every
minute, reading the undelivered rows — the partial index
`push_outbox_pending_idx` keeps that proportional to the backlog, not the
history — POSTing each one and stamping `delivered_at`, with `attempts` and
`last_error` for anything that keeps failing.

Worth saying plainly: this is **more** reliable than what it replaces. pg_net
fires and forgets inside a trigger, so a push lost to a cold start or a 500 was
lost silently. A row in a table can be retried, and you can see the backlog.

Since the app now triggers dispatch itself, you can also drop the trigger
entirely and have the Server Actions do the work — but keep the outbox: it is
what makes a missed push visible instead of invisible.

---

## Phase 5 — verification

The existing suites first: `npm run typecheck`, `npm run lint`, `npm run test`
(125 tests), then `npm run test:stress` with `STRESS_DB_URL` pointed at Neon, then
the manual checklist in `DEPLOYMENT.md` §8 against a Neon-backed preview
deployment.

Then the matrix that does not exist yet, and is the one that matters. **23
policies, and for each: an allowed case, a denied case, and a no-session case.**
Every assertion must run as `app_user` over a real connection — not as the
database owner, which bypasses RLS and makes every check pass falsely. The
checks from Phase 1 above are the skeleton; the gaps worth adding are the ones
this project has been bitten by before: a *different* driver gets `42501` rather
than silently succeeding; a moderator reading `order_messages` gets zero rows
including messages they sent themselves; the three deny-all tables raise for
everyone; and two concurrent identical bulk approvals produce exactly one
`distribution_approved` history row per order.

Then a bcrypt check against a real exported hash, and a `SET LOCAL` leak test on
the **pooled** connection string specifically — the pre-flight test above, run as
an automated assertion rather than by hand.

Add all of it to `scripts/` so Phase 6 can run it as a gate rather than a vibe.

---

## Phase 6 — cutover (the only phase that touches production)

Pick the quietest hour. Egypt is UTC+2 or +3; the orders table's own
`created_at` histogram will tell you when nobody is working.

1. Announce the window. Put the app in maintenance mode.
2. Final export from Supabase, `--data-only`, in FK order:
   `profiles → regions → driver_regions → factories → manager_factories → orders → order_history → order_messages → order_delivery_codes → order_pickup_codes → notifications → push_subscriptions → app_settings`.
   `profiles.id` values are plain UUIDs and are **preserved, not remapped** —
   every FK in the schema points at `profiles.id`, so a straight copy is correct
   and there is nothing to rewrite. The only FK to `auth.users` was
   `profiles.profiles_id_fkey`, which the shim drops.
3. Import into Neon over the **direct** connection string.
4. Import the password hashes into `profiles.password_hash` (or set
   `password_set = false` for everyone, per the pre-flight).
5. Run the Phase 5 gate. **If anything fails, stop here** — nothing has changed
   for users yet.
6. Verification before flipping: row count per table on both sides must match
   exactly; every `profiles.id` on Neon must exist on Supabase with the same
   phone number (the independent cross-check — matching by phone *verifies* the
   copy, it is not what determines the id); zero orphan FKs; `max(created_at)`
   per table equal on both sides.
7. Swap the Vercel env vars: remove `NEXT_PUBLIC_SUPABASE_URL`,
   `NEXT_PUBLIC_SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`; add
   `DATABASE_URL` (pooled), `DATABASE_URL_UNPOOLED` (direct), `SESSION_SECRET`.
   The four push vars — `NEXT_PUBLIC_VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`,
   `VAPID_SUBJECT`, `PUSH_WEBHOOK_SECRET` — are unchanged, and **must** be: a new
   VAPID key pair silently invalidates every registered device.
8. Set `push_endpoint_url` and `push_webhook_secret` in `app_settings` on Neon.
9. Redeploy. Smoke test as each role on a real phone: owner signs in and sees the
   dashboard; moderator creates an order end to end; driver signs in, sees it,
   presses through to delivered with the real codes; the push arrives; the bell
   shows it; the repeat-customer popup fires on a second order for the same number.
10. Lift maintenance mode. Watch for an hour.

Rollback is the env vars, back. Supabase is untouched by every step above, so it
stays a working system you can point at again in a minute — which is the reason
step 5 is a hard stop rather than a judgement call.

---

## Phase 7 — cleanup, after a retention window

One to two weeks of Neon running clean, then: remove `@supabase/ssr` and
`@supabase/supabase-js`, delete `src/lib/supabase/`, update `DEPLOYMENT.md` and
`HANDOVER.md`, take a final Supabase backup and keep it somewhere cold, then
decommission the Supabase project.

Two security cleanups worth doing in the same pass, both found during the audit
and neither strictly part of the migration: `public_create_order` is still
granted to `anon` even though the public order form became a redirect long ago,
so nothing calls it — revoke it, or drop the function. And
The former stress-test script's test 4 self-skipped when no factory account was seeded,
which since migration 0033 is always, so it silently tests nothing.
