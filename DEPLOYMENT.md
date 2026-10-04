# Deployment Guide

Standing the system up from nothing: a Neon Postgres database, a Vercel
deployment, push notifications, and the first account.

Nothing here needs a terminal. Everything runs in the Neon SQL Editor and the
Vercel dashboard.

> **Replaced Supabase.** This used to be a Supabase project — Postgres plus
> their Auth service plus their auto-generated REST API. It now runs on plain
> Postgres: the app connects with a database driver, sessions are a signed
> cookie, and passwords are hashed and verified inside Postgres. There is no
> `SUPABASE_*` variable anywhere any more. `neon/RUNBOOK.md` records why each
> piece is the way it is.

---

## 1. Create the Neon project

Pick the region closest to your Vercel deployment. The app is query-chatty on
the order pages and a cross-continent hop is paid on every one of them.

From **Connection Details**, keep both strings:

- the **pooled** string — host contains `-pooler`. What the app uses.
- the **direct** string — same host without `-pooler`. For schema changes and
  backups, which need session-level features the pooler refuses.

Scale-to-zero can stay on.

## 2. Create the tables

Open **SQL Editor**. Run the six files in `neon/bundled/` in order — paste
one, run it, wait for it to finish, then the next.

| | File | What it adds |
|---|---|---|
| 1 | `part1_of_6.sql` | roles, schemas, tables, the core order workflow |
| 2 | `part2_of_6.sql` | chat, delivery/pickup codes, reports, region matching |
| 3 | `part3_of_6.sql` | factories, bulk distribution, push subscriptions |
| 4 | `part4_of_6.sql` | one migration, alone — see below |
| 5 | `part5_of_6.sql` | driver field orders, repeat-customer check, the role-guard fix |
| 6 | `part6_of_6.sql` | auth: passwords, login, throttling |

**Part 4 is alone deliberately.** It adds a value to the `order_source` enum,
and Postgres will not let a later statement *use* a new enum value in the same
transaction — which is exactly what part 5 does. A SQL editor runs your whole
paste as one transaction, so combining them fails. Every part is idempotent,
so re-running one after losing your place is safe.

These files are generated from `supabase/migrations/` plus `neon/migrations/`
by `scripts/build-neon-bundle.mjs`. After adding a migration, re-run that
script rather than editing them.

### What should exist afterwards

```sql
select (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and c.relkind = 'r')          as tables,
       (select count(*) from pg_policies where schemaname = 'public') as policies,
       (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
         where n.nspname = 'public' and c.relrowsecurity)         as tables_with_rls,
       (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public' and p.prosecdef)              as security_definer_functions;
```

Expect 15 tables, every one of them with row-level security on, 23 policies,
and 71 `SECURITY DEFINER` functions.

## 3. Set the application's database password

```sql
alter role app_user with login password 'A-STRONG-PASSWORD-FROM-YOUR-MANAGER';
```

`app_user` is what the app connects as — deliberately not the Neon owner role.
It cannot bypass row-level security, so a compromised application still only
sees what the signed-in person is allowed to see. That property is worth
protecting: never point `DATABASE_URL` at the owner role to "fix" a permission
error, because it fixes it by turning the security model off.

Build the two connection strings by substituting this user and password into
the ones from step 1:

```
postgresql://app_user:PASSWORD@ep-xxxx-pooler.REGION.aws.neon.tech/neondb?sslmode=require
postgresql://app_user:PASSWORD@ep-xxxx.REGION.aws.neon.tech/neondb?sslmode=require
```

## 4. Generate the push keys

Only on a first-ever deploy. **Never regenerate these for an existing
system** — a new VAPID pair silently invalidates every phone already
registered, and nobody gets a notification again until each person re-enables
it on their own device.

```bash
node -e "const w=require('web-push'),c=require('crypto');const k=w.generateVAPIDKeys();
console.log('NEXT_PUBLIC_VAPID_PUBLIC_KEY='+k.publicKey);
console.log('VAPID_PRIVATE_KEY='+k.privateKey);
console.log('PUSH_WEBHOOK_SECRET='+c.randomBytes(32).toString('base64url'));"
```

Keep the output in a password manager. The private key is not recoverable.

## 5. Deploy to Vercel

Import the GitHub repository. Framework detection and build settings need no
changes.

### Environment variables

| Name | Value | Secret |
|---|---|---|
| `DATABASE_URL` | the **pooled** string from step 3 | yes |
| `DATABASE_URL_UNPOOLED` | the **direct** string from step 3 | yes |
| `SESSION_SECRET` | 32+ random characters | yes |
| `NEXT_PUBLIC_VAPID_PUBLIC_KEY` | from step 4 | no — it ships to the browser by design |
| `VAPID_PRIVATE_KEY` | from step 4 | yes |
| `VAPID_SUBJECT` | `mailto:you@yourbusiness.com` | no |
| `PUSH_WEBHOOK_SECRET` | from step 4 | yes |

For `SESSION_SECRET`, run `select encode(gen_random_bytes(48), 'base64');` in
the SQL editor. It signs the login cookie, and the app refuses to start if it
is shorter than 32 characters. Changing it later signs everyone out
immediately — which is also how you revoke every session at once if you ever
need to.

Set all of them for Production, Preview and Development, or preview
deployments will fail to boot.

### Point the database at the app

The database tells the app when to send a push, so it needs the URL and the
same secret:

```sql
insert into public.app_settings (key, value) values
  ('push_endpoint_url', 'https://YOUR-DOMAIN/api/push/dispatch'),
  ('push_webhook_secret', 'THE SAME VALUE AS PUSH_WEBHOOK_SECRET IN VERCEL')
on conflict (key) do update set value = excluded.value;
```

If the secret does not match exactly, the endpoint rejects every request and
no notification is ever sent, with nothing in any log to say why. If you later
change the domain, update `push_endpoint_url` too.

`app_settings` has row-level security on and no policies, so nobody can read
these values back through the application — only a database session can.

## 6. Create the first account

Open **`/setup`**. It works only while no owner exists, and stops the moment
you submit. Enter a name, a phone number as `01xxxxxxxxx`, and a password; it
signs you in.

Use a phone number you actually have. It is the login, and there is no email
recovery path by design.

Then, in **الفريق**:

1. **المصانع first.** Choosing a factory is mandatory when creating an order,
   so with an empty list no order can be created. Paste each factory's Google
   Maps share link into the موقع field and the pin places itself.
2. **الموظفون.** Name, phone, role, and for drivers their coverage areas. You
   never type a password for anyone: each person enters their phone number on
   the login page and chooses their own password. Areas are typed, not picked
   from a list — use one spelling per area and keep to it, because orders are
   matched to drivers by that name.
3. **Managers → factories.** A manager with no factories assigned gets no chat
   notifications.

## 7. Turn on push, per person and per device

Push is per device, not per account. Each person signs in, opens their home
page, and presses the button on the notifications card.

On **iPhone** this only works from a Home Screen install: Share → Add to Home
Screen, then open it from that icon. Safari in a normal tab cannot receive
push. On **Android** it works in Chrome directly.

Drivers are notified when an order is assigned to them. Managers are notified
about chat on an order for a factory they manage. Moderators get one kind of
notification only — that an order was delivered.

## 8. Post-deploy checklist

Security first, because it is the part nobody notices is wrong:

- [ ] `supabase/maintenance/verify_role_guards.sql` in the SQL editor — 10
      checks, all PASS. This is the one that catches an authorization guard
      falling open.
- [ ] `DATABASE_URL` points at `app_user`, not the Neon owner role:
      `select current_user, rolsuper, rolbypassrls from pg_roles where rolname = current_user;`
      — expect `app_user`, `f`, `f`.
- [ ] Response headers on the live site include `Content-Security-Policy` and
      `Strict-Transport-Security`.
- [ ] Signed out, `/owner` redirects to `/login`.

Then the workflow, end to end, with a real phone for the driver part:

- [ ] A moderator creates an order. It needs a Google Maps link for the
      customer's location (mandatory) and a factory.
- [ ] It appears under التوزيع grouped by area with a suggested driver. The
      manager approves it.
- [ ] The driver signs in on their phone, presses through every step to
      delivered, using the pickup and delivery codes.
- [ ] The push arrives and the bell shows it.
- [ ] A second order for the **same customer phone** pops the repeat-customer
      confirmation before anything is created.
- [ ] `/track` finds an order by its number plus the customer's phone.

---

## Operating notes

**Backups.** Neon keeps point-in-time restore according to your plan; check
the retention window matches what you would need, and take a manual export
before any schema change.

**Schema changes.** Apply new migrations with the **direct** connection
string, never the pooled one. Add them to `supabase/migrations/` and re-run
`scripts/build-neon-bundle.mjs`.

**Starting over.** `supabase/maintenance/reset_all_data.sql` empties every
account and order while keeping the schema and the push configuration. It
refuses to run until you edit one line, and it tells you what it is about to
delete before it does it.

**Connection limits.** Each Vercel instance keeps its own pool, so the real
connection count is `DATABASE_POOL_MAX` times the number of warm instances.
The default of 5 suits this workload; raise it only with that multiplication
in mind.
