# How the database is built, and why

Operational notes for whoever maintains this system. Not a plan — the move off
Supabase is finished. This records the decisions that are easy to undo by
accident, each one written because getting it wrong cost real time.

For standing the system up from nothing, see `NEW-ACCOUNT-SETUP.md`.

---

## The layout

```
db/migrations/    the numbered migration chain — the source of truth
db/neon/          the pieces specific to running on plain Postgres
db/bundled/       GENERATED — paste these four into the SQL editor
db/maintenance/   verification and reset scripts
```

`db/bundled/` and `db/maintenance/check_schema_parts.sql` are both produced by
`node scripts/build-neon-bundle.mjs`. Add a migration, re-run that — never edit
the generated files, because the next run overwrites them.

The chain skips `0044_region_boundaries.sql`, which installs PostGIS for a
map feature that was cancelled. Nothing references it. A naive
`for f in db/migrations/*.sql` loop would install PostGIS for no reason; the
bundler leaves it out deliberately.

---

## The four things most likely to be broken by accident

**1. `DATABASE_URL` must point at `app_user`, never the owner role.**

The owner bypasses row-level security. Point the app at it to "fix" a
permission error and you have fixed it by switching the security model off,
with nothing visibly wrong. Check with:

```sql
select current_user, rolsuper, rolbypassrls from pg_roles where rolname = current_user;
```

Expect `app_user`, `f`, `f`.

**2. The identity is transaction-local, and must stay that way.**

`src/lib/db/with-user-context.ts` sets `app.current_profile_id` with
`set_config(..., true)` inside a transaction. A session-level `SET` was
measured to survive `COMMIT` and leak into whatever request reused that pooled
connection next — one person seeing another person's rows. Neon's pooler is
PgBouncer in transaction mode, so this is not theoretical.

`scripts/verify-db-layer.mjs` asserts the leak is closed. Run it after
touching anything in `src/lib/db/`.

**3. Never set `rejectUnauthorized: false` on the connection.**

`src/lib/db/pool.ts` exempts loopback addresses from TLS verification and
verifies everything else. Accepting any certificate is worse than no TLS,
because it looks encrypted.

**4. Authorization guards must fail closed.**

In plpgsql, `if not NULL` takes neither branch. 49 guards were written as
`if not is_owner()` where `is_owner()` could return NULL for a signed-out
caller — so the guard silently passed. `0051_fail_closed_role_guards.sql`
wraps them in `coalesce(..., false)` and refuses to apply if a NULL is
reintroduced. `db/maintenance/verify_role_guards.sql` is the standing check:
ten assertions, all should say PASS.

---

## Things that look wrong but are deliberate

**`UserRole` still includes `"factory"`.** Factory accounts were retired and
`profiles` has `check (role <> 'factory')`, but `order_history.actor_role` and
`order_messages.sender_role` hold historical `'factory'` values that must keep
rendering. Postgres has no `ALTER TYPE ... DROP VALUE`, and the TypeScript
union mirrors the enum.

**`create_order_internal` has no caller check.** It is the shared helper behind
`moderator_create_order` and `driver_create_field_order`, which do the
checking. What keeps it safe is that `app_user` has no `EXECUTE` on it — only
the `SECURITY DEFINER` wrappers can reach it, and they run as the owner.
`0052_drop_public_create_order.sql` revokes it and refuses to apply if the
revoke did not take.

**Report functions in `src/lib/data/orders.ts` look unused.** `getDailyReport`,
`getMonthlyReport` and the rest have no production caller — the page uses the
batched `getReportsPageData()`. They are kept as the reference the batched
version is diffed against in `src/lib/db/__tests__/read-batch.test.ts`.
Deleting them removes the only check that batching did not reorder the
results.

**The chat message read is newest-first-then-reversed, not ascending.**
Ascending with a `LIMIT` keeps the OLDEST 200 messages and hides everything
current.

---

## Push, without pg_net

On Supabase the notification trigger called `net.http_post()` from inside
Postgres. Plain Postgres cannot make an HTTP request, so `db/neon/0000_prelude.sql`
provides a stand-in with the same signature that writes the request into
`public.push_outbox` instead.

Something outside the database has to drain that table. That something is
`src/lib/push/outbox.ts`, scheduled with `after()` from the request that
created the notification. There is no cron job, by choice: a schedule costs a
Vercel invocation whether or not anything is waiting, and on the Hobby plan
the finest interval is daily.

If notifications stop, look here first:

```sql
select id, created_at, attempts, delivered_at, last_error
from public.push_outbox order by id desc limit 20;
```

`delivered_at` set means sent. Blank with a `last_error` says why. Everything
pending with no error means nothing is draining the queue.

The single most common cause of silence is `push_webhook_secret` in
`app_settings` not matching `PUSH_WEBHOOK_SECRET` in Vercel exactly. The
endpoint rejects every mismatched request and logs nothing, deliberately.

---

## Cost

Neon bills CU-hours — compute size times the time the compute is **awake** —
and suspends after five minutes with no query. So the bill is driven by how
many minutes a day something touches the database, not by how many queries
each page runs.

That is why the chat poll stops entirely when the tab is hidden rather than
slowing to 60s. Anything that queries more often than every five minutes keeps
the compute awake permanently: one order page left open in a background tab
was enough to hold it awake 24 hours a day.

Compute size is worth checking in the Neon console. Autoscaling to 2 CU costs
up to eight times the 0.25 CU base rate under load, and this workload — tens
of megabytes, a handful of users — never needs it.

---

## Running the checks

All of them connect as `app_user`, never the owner, because the owner bypasses
RLS and would make every check pass falsely.

```bash
DATABASE_URL=... node scripts/verify-db-layer.mjs           # 34 checks
DATABASE_URL=... node scripts/verify-dashboard-values.mjs   # 23 checks
```

In the SQL editor:

- `db/maintenance/verify_role_guards.sql` — 10 authorization checks
- `db/maintenance/check_schema_parts.sql` — which bundle part did not finish
- `db/maintenance/schema_fingerprint.sql` — full structural snapshot, for
  diffing two databases
- `db/maintenance/reset_all_data.sql` — empties accounts and orders, keeps the
  schema and push settings. Refuses to run until you edit one line.

The unit suite skips every database test unless `DATABASE_URL` is set:

```bash
DATABASE_URL=... ADMIN_DATABASE_URL=... npm test
```

Without those, the suite still passes while asserting nothing about the
database. `ADMIN_DATABASE_URL` is the owner connection, used only to look
things up that RLS hides from the test harness.
