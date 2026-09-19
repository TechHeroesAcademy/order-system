# Neon migration scripts

This directory is **not** part of the Supabase migration chain in `supabase/migrations/` — it's kept deliberately separate. Full context: the "neon-migration-guide.md" doc in this project's Claude project (and the plan behind it).

## Why this is a separate directory, not `supabase/migrations/0033...`

`neon/migrations/0001_auth_shim.sql` overwrites `auth.uid()` with a version that reads identity from an app-set session variable instead of Supabase's real JWT claim. If this were ever applied to the **live Supabase project** — for example because someone runs "the next migration in numeric order" without realizing what it does — every RLS policy in production would immediately start evaluating `auth.uid()` as `NULL` for every request, since nothing there ever calls `set_current_profile_id()`. This app's policies fail closed, not open, so the practical effect would be a full production outage (nobody can see or do anything), starting the instant it runs.

The migration file itself has a guard at the top that aborts if it detects Supabase-specific columns on `auth.users` — verified directly (it does abort against a Supabase-shaped database, and does proceed against a bare Postgres one) — but the guard is a second line of defense, not a reason to get casual about where this file lives or how it's applied.

**Rule: never apply anything under `neon/migrations/` to the Supabase project. It's for a Neon (or other non-Supabase) Postgres database only, after `supabase/migrations/` 0001–0032 have already been replayed against it.**

## Applying this today (Phase 0/1 only — no production impact)

1. Create a Neon project (or a disposable Neon branch for testing).
2. Apply `supabase/migrations/0001` through `0032` against it, in order, exactly as `DEPLOYMENT.md` describes for a fresh Supabase project — this part is unmodified and portable as-is.
3. Apply `neon/migrations/0001_auth_shim.sql`.
4. Set real login passwords for the `app_user` and `app_admin` roles this migration creates — **never in a committed file**:
   ```sql
   alter role app_user with login password '<generate one, store it in your secrets manager>';
   alter role app_admin with login password '<a different one>';
   ```

Verified locally (disposable Postgres database standing in for Neon, since Neon is itself just Postgres): the schema replays cleanly end to end, `auth.uid()` returns `NULL` until `set_current_profile_id()` is called and the right value after, and — checked against a real non-superuser connection with RLS actually enforced, not bypassed — a driver can see only their own `profiles` row, and an unauthenticated connection (no session set) sees zero rows.

## What's still ahead

This is Phase 1 of the plan only: schema portability. The app itself still talks to Supabase — nothing here is wired up yet. Phases 2–7 (the custom auth layer, the data-access rewrite, the real data migration, verification, and cutover) are tracked separately; see the project doc for the full sequencing and why production stays untouched until the very last phase.
