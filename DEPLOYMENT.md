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
`0001_extensions_and_enums.sql` through `0011_table_grants.sql`. Wait for
each to succeed before running the next — later files depend on earlier ones.

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

In **Authentication → Providers**, keep only **Email** enabled — there is no
public sign-up flow in this app, all accounts are created by the Owner from
`/owner/team`, which triggers `resetPasswordForEmail` so new team members set
their own password on first login.

In **Authentication → URL Configuration**, set:
- **Site URL** → your production URL (e.g. `https://orders.yourbusiness.com`)
- **Redirect URLs** → add the same URL (and your Vercel preview domain
  pattern if you want password-reset links to work on preview deployments too)

## 5. Deploy to Vercel

1. Push this repository to GitHub/GitLab/Bitbucket.
2. Go to [vercel.com/new](https://vercel.com/new) and import the repository.
3. Framework preset: **Next.js** (auto-detected).
4. Add the three environment variables from step 1 under **Settings →
   Environment Variables** (for both Production and Preview environments):
   - `NEXT_PUBLIC_SUPABASE_URL`
   - `NEXT_PUBLIC_SUPABASE_ANON_KEY`
   - `SUPABASE_SERVICE_ROLE_KEY`
5. Deploy. Vercel will run `npm run build` automatically.

## 6. Create the first Owner account

There is no bootstrap UI for the very first account (by design — every other
account is created by an Owner). Create it directly in Supabase once:

1. **Authentication → Users → Add user** in the Supabase dashboard. Set an
   email and password, and enable **Auto Confirm User**.
2. Go to **Table Editor → profiles**, find the row created automatically for
   that user (via the `handle_new_user` trigger), and set `role` to `owner`
   and `is_active` to `true`.
3. Log in at `/login` with that email/password — you now have full Owner
   access and can create every other account from `/owner/team`.

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
