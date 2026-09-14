# نظام إدارة وتتبع الأوردرات (Order Management & Tracking System)

Production-ready order management system for a tailoring/garment business that
replaces manual phone + WhatsApp/Messenger + paper tracking. Built with
Next.js (App Router), Supabase (Postgres + Auth + RLS), and Tailwind CSS,
fully in Arabic with RTL layout and a mobile-first driver interface.

## Stack

- **Next.js 16** (App Router, Turbopack, Server Actions) + TypeScript
- **Tailwind CSS v4** + hand-built shadcn/ui-style components (Radix UI primitives)
- **Supabase**: Postgres, Auth, Row Level Security, SECURITY DEFINER RPCs
- **Vercel** for hosting
- **Zod** + **react-hook-form** for validation
- **Vitest** + Testing Library for unit tests

## Core workflow

```
Order created (website or Messenger via Moderator)
  → unique order number (ORD-0001) + 4-digit delivery code generated
  → Owner/Moderator suggests a driver → Owner approves distribution
  → Driver collects from customer
  → Driver hands off to factory → Factory confirms receipt
  → Factory finishes work → marks ready
  → Same driver picks up from factory
  → Driver delivers to customer, validates the 4-digit delivery code
  → Order closed (delivered), or refused/cancelled as terminal side-exits
```

Every transition is enforced **in the database**, not just in the UI: each
step is a `SECURITY DEFINER` RPC in `supabase/migrations/0009_workflow_rpcs.sql`
that re-checks the caller's role and the order's current status before doing
anything. Row Level Security blocks any other direct write. This means the
workflow can't be bypassed even if someone calls the Supabase API directly.

## Roles & interfaces

| Role | Route | What they do |
|---|---|---|
| Owner | `/owner` | Full dashboard, all orders, approve driver distribution, reports/analytics, team & region management |
| Moderator | `/moderator` | Create orders from Messenger/phone, suggest driver distribution, view all orders |
| Driver | `/driver` | Mobile-first list of assigned orders, collect/hand-off/pickup/deliver actions, delivery code entry, refusal logging |
| Factory | `/factory` | Search/list orders in production, confirm receipt, mark ready |
| Customer (public) | `/order/new`, `/track` | Submit a new order from the website, track an existing order by order number + phone |

Team accounts (Owner/Moderator/Driver/Factory) are created by the Owner from
`/owner/team` — no public sign-up.

## Project structure

```
src/
  app/                 Routes (App Router) — one folder per role + public pages
  components/
    ui/                Hand-built shadcn/ui-style primitives (button, dialog, table, ...)
    orders/            Order-specific UI (form, table, timeline, status badge, distribution panel)
    layout/             AppShell (header/nav/notifications), sign-out
    driver/ factory/ team/   Role-specific components
    shared/            Generic building blocks (StatCard, EmptyState, ConfirmActionButton)
  lib/
    actions/           Server Actions ("use server") — the only way the client writes data
    data/              Server-only read helpers (Server Components use these)
    domain/            Zod schemas, order-status helpers, formatting — unit tested
    supabase/          Supabase client factories (browser / server / admin / middleware)
    auth.ts            requireRole() guard used by every protected page/action
  types/database.ts    Hand-written types mirroring the Postgres schema
supabase/
  migrations/          Numbered SQL migrations — run in order, this is the source of truth
  seed.sql             Demo users, regions, and sample orders for local/dev use
```

## Environment variables

Copy `.env.example` to `.env.local` and fill in the three values from your
Supabase project (`Project Settings → API`):

```
NEXT_PUBLIC_SUPABASE_URL=https://YOUR-PROJECT-REF.supabase.co
NEXT_PUBLIC_SUPABASE_ANON_KEY=your-anon-public-key
SUPABASE_SERVICE_ROLE_KEY=your-service-role-key   # server-only, never exposed to the browser
```

The service-role key is used only inside Server Actions (`src/lib/actions/admin.ts`)
to create staff accounts through the Supabase Admin API — it is never sent to
the browser and `src/lib/supabase/admin.ts` is marked `server-only` to make
that a build-time guarantee, not just a convention.

## Running locally

Requirements: Node.js 20+, a Supabase project (or the Supabase CLI for a local stack).

```bash
npm install
cp .env.example .env.local     # fill in your Supabase values
npm run dev                    # http://localhost:3000
```

Before the app is useful you need the database schema and seed data — see
**DEPLOYMENT.md** for the exact Supabase setup steps (running the migrations
in `supabase/migrations/`, then `supabase/seed.sql` for demo accounts).

### Scripts

```bash
npm run dev         # start dev server (Turbopack)
npm run build        # production build
npm run start        # run the production build
npm run lint          # ESLint
npm run typecheck    # tsc --noEmit
npm run test          # run unit tests once (Vitest)
npm run test:watch   # unit tests in watch mode
```

## Testing

- **Unit tests** (`src/lib/domain/__tests__/`, 18 tests): the order-status
  state machine helpers and every Zod validation schema.
- **Database-level verification**: the entire workflow (order creation, RLS
  isolation between roles, driver suggestion ranking, distribution + Owner
  approval, every status transition, correct vs. incorrect delivery-code
  handling, public tracking) was exercised end-to-end against a real
  Postgres instance running the exact migrations in this repo, simulating
  each role via Postgres session variables — not just mocked. See
  **DEPLOYMENT.md → "Testing results"** for what was verified.
- Run `npm run test`, `npm run typecheck`, `npm run lint`, and `npm run build`
  before any deploy — all four are expected to pass cleanly.

## Security notes

- **RLS is the real boundary, not the UI.** `proxy.ts` and `requireRole()`
  keep people out of the wrong screens for UX purposes, but every actual
  permission check is enforced again in Postgres (RLS policies + role checks
  inside each RPC), so a modified client or a direct API call can't skip a
  step or act outside its role.
- **Delivery codes are never stored in plaintext** — only a `pgcrypto` hash.
  The code is shown once, at order creation, so it can be written on the
  paper receipt; validating it later goes through a `SECURITY DEFINER`
  function that compares hashes and never exposes the stored value.
- **`anon` (unauthenticated) access is minimal by design**: only the two
  order-creation RPCs and order tracking are reachable without login: no
  table is directly readable by an anonymous client.

## What was intentionally left out

Per the brief ("do not invent unnecessary features, keep it simple"), this
build does not include a real Meta/Facebook Messenger webhook integration —
no Messenger API credentials were available. Instead, `order_source` is a
proper enum (`website` / `messenger`) and the Moderator's manual-entry form
(`/moderator/orders/new`) is exactly the intake path a real Messenger webhook
would call into later — wiring a webhook is an additive change, not a
redesign. See HANDOVER.md for details.
