# Deployment Guide

This covers taking the app from this repository to a live Supabase project
and a live Vercel deployment.

## 1. Create the Supabase project

1. Go to [supabase.com](https://supabase.com) → New Project. Pick a region
   close to your users (e.g. an EU or Middle East region for lower latency
   from Egypt).
2. Once created, go to **Project Settings → API** and note down:
   - `Project URL` → this is `NEXT_PUBLIC_SUPABASE_URL`
   - `anon public` key → this is `NEXT_PUBLIC_SUPABASE_ANON_KEY`
   - `service_role` key → this is `SUPABASE_SERVICE_ROLE_KEY` (keep this
     secret — it bypasses RLS entirely)

## 2. Run the database migrations

The schema is entirely in `supabase/migrations/`, numbered in the order they
must run. Two ways to apply them:

### Option A — Supabase Dashboard (simplest, no CLI needed)

Open **SQL Editor** in the Supabase dashboard and run each file in
`supabase/migrations/` **in numeric order**, one at a time, from
`0001_extensions_and_enums.sql` through the highest-numbered file in that
folder. Wait for each to succeed before running the next — later files
depend on earlier ones. Every migration is safe to re-run from a clean
database in order (each one that redefines a function drops it first where
Postgres requires that).

### Option B — Supabase CLI

```bash
npm install -g supabase
supabase login
supabase link --project-ref YOUR-PROJECT-REF
supabase db push
```

This applies every migration in `supabase/migrations/` in order.

## 3. (Optional) Load demo/seed data

`supabase/seed.sql` creates 5 demo accounts (owner, moderator, 2 drivers,
factory — all password `Passw0rd!`), 5 regions, and 9 sample orders covering
every status. Useful for a demo or staging environment — **do not run this
against production**, it creates fake accounts and orders.

Run it the same way as a migration (SQL Editor or `supabase db push` after
adding it temporarily to the migrations folder), then delete the demo
accounts before going live, or use a separate staging project entirely for
demos.

## 4. Configure Supabase Auth

Everyone signs in with a phone number and a password they set themselves —
there is no email/password login anywhere in the app, not even for the
Owner. Every Supabase Auth user still technically has an email under the
hood (the Auth Admin API requires one), but it's a synthetic internal
address like `owner-<uuid>@workers.internal` that's never shown to anyone
or used for sign-in — all lookups go through `phone` on the `profiles`
table via the service-role client.

In **Authentication → Providers**, keep only **Email** enabled (it's the
underlying mechanism Supabase Auth itself needs — end users never see it).
No SMS/OTP provider is needed; this isn't OTP-based, it's a normal
password login keyed by phone number instead of email.

In **Authentication → URL Configuration**, set:
- **Site URL** → your production URL (e.g. `https://orders.yourbusiness.com`)
- **Redirect URLs** → add the same URL (and your Vercel preview domain
  pattern if you use preview deployments)

## 5. Deploy to Vercel

1. Push this repository to GitHub/GitLab/Bitbucket.
2. Go to [vercel.com/new](https://vercel.com/new) and import the repository.
3. Framework preset: **Next.js** (auto-detected).
4. Add the three environment variables from step 1 under **Settings →
   Environment Variables** (for both Production and Preview environments):
   - `NEXT_PUBLIC_SUPABASE_URL`
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY`
   - `SUPABASE_SERVICE_ROLE_KEY`

   Plus four more if you want phone push notifications — see
   [§5a](#5a-push-notifications-optional). Without them the app runs
   exactly as before, with in-app notifications only.
5. Deploy. Vercel will run `npm run build` automatically.

## 5a. Push notifications (optional)

Drivers get a notification on their phone the moment an order is assigned
to them, and managers get one when a driver writes on an order for a
factory they cover. This uses the browser's own Web Push — no Firebase, no
third-party account, no SDK. Skip this section entirely and everything else
still works; notifications just stay inside the app.

### Generate the keys

Run this once, on your own machine, in a checkout of this repo:

```bash
node -e "const w=require('web-push'),c=require('crypto');const k=w.generateVAPIDKeys();
console.log('NEXT_PUBLIC_VAPID_PUBLIC_KEY='+k.publicKey);
console.log('VAPID_PRIVATE_KEY='+k.privateKey);
console.log('PUSH_WEBHOOK_SECRET='+c.randomBytes(32).toString('base64url'));"
```

Generate these yourself rather than accepting keys from anyone — the
private key is what proves a push came from your server, and anyone holding
it can send notifications to your staff's phones.

Keep the output. **If you lose the VAPID private key, or change it, every
device that already turned notifications on stops receiving them** and each
person has to switch them on again. Store it wherever you keep the Supabase
service-role key.

### Add them to Vercel

Four variables, **Production and Preview**:

| Variable | Value |
|---|---|
| `NEXT_PUBLIC_VAPID_PUBLIC_KEY` | from the command above (this one is public — it ships to the browser by design) |
| `VAPID_PRIVATE_KEY` | from the command above — secret |
| `PUSH_WEBHOOK_SECRET` | from the command above — secret |
| `VAPID_SUBJECT` | `mailto:you@yourbusiness.com` — a contact address, required by the spec so a push service can reach you |

Redeploy after adding them.

### Point the database at the app

Run this once in the Supabase SQL editor, with your real domain and the
same secret you just put in Vercel:

```sql
alter database postgres
  set app.push_endpoint_url = 'https://orders.yourbusiness.com/api/push/dispatch';
alter database postgres
  set app.push_webhook_secret = 'the same value as PUSH_WEBHOOK_SECRET';
```

These are deliberately not in any migration file — a committed migration is
the wrong place for a credential. They take effect on new database
connections, so allow a minute before testing.

To switch push off later without reverting anything:

```sql
alter database postgres reset app.push_webhook_secret;
```

### Turn it on, per person and per device

Each person taps **تفعيل الإشعارات** on their dashboard and allows the
browser prompt. It is per device, so someone using a phone and a laptop
turns it on twice.

**On iPhone and iPad this only works after adding the app to the Home
Screen**, on iOS 16.4 or newer. That is an Apple platform rule, not
something the app can work around: iOS gives web apps notifications only
once installed, and never in a normal Safari tab. The app detects this and
shows the install steps instead of a button that would fail. Android needs
no install — it works straight from the browser.

### Assign managers to factories

A manager's phone only rings for chat on orders belonging to a factory they
cover, and **a manager with no factories assigned gets no chat
notifications at all**. Set this at `/owner/team` → the factory button on
each manager's row.

This affects notifications only. Every manager still sees every order and
every notification in the bell, exactly as before.

## 6. Create the first Owner account

No Supabase dashboard step needed — visit `/setup` on the live site once.
It's a self-service bootstrap page: enter a name, phone number, and a
password, and it creates the Owner account and signs you straight in. It's
gated server-side (both at the page level and inside the Server Action) on
"does a `profiles` row with `role = 'owner'` already exist" — once one does,
`/setup` just shows a link to `/login` instead of the form, so it can't be
used to create a second Owner or be left reachable as an open door.

If an Owner account was already created the old way (directly in the
Supabase dashboard, before this flow existed) it won't have a `phone` set
and won't work with phone login — either set its `phone` column manually in
**Table Editor → profiles**, or just use `/setup` fresh on a project that
has no Owner yet.

## 7. Post-deploy checklist

- [ ] Visit the production URL, confirm the public homepage, `/order/new`,
      and `/track` all load.
- [ ] Log in as the Owner, add your real regions under `/owner/team`.
- [ ] Create your real Moderator/Driver/Factory accounts (assign regions to
      each driver).
- [ ] Submit a test order end-to-end through every role to confirm emails/
      notifications and the full status flow work in your live project.
- [ ] Remove or rotate the demo seed accounts if you loaded `seed.sql`
      anywhere reachable by real users.
- [ ] In Supabase, confirm **Database → Backups** is enabled (Pro plan or
      above) or set up your own backup schedule — this is business-critical
      data.

## Testing results (verified during development)

Because a live Supabase project wasn't available during the build, the
entire backend was verified against a real local PostgreSQL 16 instance
running the exact SQL in `supabase/migrations/`, with a minimal stub of
Supabase's `auth` schema so the same RLS policies and RPCs could be exercised
as they would run in production. Each role was simulated via Postgres
session variables (`request.jwt.claim.sub`, `role authenticated`), not
mocked in application code. Confirmed:

- Order creation via both `public_create_order` (website, unauthenticated)
  and `moderator_create_order` (staff), including unique order-number
  generation and delivery-code hashing.
- `anon` (unauthenticated) clients are blocked from reading `orders`,
  `order_history`, and `notifications` directly — the only anonymous paths
  are the create/track RPCs.
- Driver suggestion ranking (`suggest_drivers`) and the distribution →
  Owner-approval flow, including rejecting a Moderator's attempt to approve
  (Owner-only).
- Every status transition in order: `new → assigned → collected → at_factory
  → ready → with_driver → delivered`, each performed by the correct role and
  rejected when attempted by the wrong role or out of sequence.
- Delivery-code validation: a wrong code is rejected and logged as a
  mismatch without closing the order; the correct code closes it.
- Public order tracking (`track_order`) returns status without exposing
  other customers' data.
- An unassigned driver is correctly blocked from acting on an order that
  isn't theirs.

On top of that, the application layer has:

- 18 passing unit tests (`npm run test`) covering the order-status state
  machine and every Zod validation schema.
- A clean `npm run typecheck`, `npm run lint`, and `npm run build` — verified
  after every implementation phase, not just once at the end.

What has **not** been tested: a real Supabase project's network behaviour
(latency, connection pooling under load), real email deliverability for the
password-reset flow, and browser/device testing of the driver UI on physical
phones. Do the post-deploy checklist above against your real project before
handing this to end users, and test the driver flow on an actual phone.
