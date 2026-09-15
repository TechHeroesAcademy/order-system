# End-to-end tests

Real browser tests via Playwright, split into two files on purpose:

## `public.spec.ts` — runs anywhere, no setup

Covers every unauthenticated page: the homepage, `/order/new`, `/track`,
`/login`, and the redirect-to-login behavior of every role-gated dashboard.
Nothing here needs a working Supabase project, so it runs against a fresh
`npm run build && npm run start` with no configuration:

```bash
npm run test:e2e -- e2e/public.spec.ts
```

Two of these are regression tests for real bugs this suite caught during
development — see the comments at the top of the file. Keep them; they're
cheap insurance against the same class of bug coming back.

## `staff-lifecycle.spec.ts` — needs a real Supabase project + seeded staff

Walks the entire order journey (spec section 14) across all four roles in
separate browser contexts — Moderator registers an order, Owner distributes
and approves it, the Driver takes it through pickup → factory → delivery
with the real confirmation code, and the customer tracks it to "delivered"
with no login at all. This can't run against a placeholder backend because
signing in requires a real Supabase Auth server.

Point it at a real project (a staging project, or a disposable branch — never
production) with seeded staff accounts (`supabase/seed.sql` works, or your
own), then run:

```bash
E2E_BASE_URL=https://your-staging-url.example.com \
E2E_OWNER_PHONE=01000000001     E2E_OWNER_PASSWORD=Passw0rd! \
E2E_MODERATOR_PHONE=01000000002 E2E_MODERATOR_PASSWORD=Passw0rd! \
E2E_DRIVER_PHONE=01000000003    E2E_DRIVER_PASSWORD=Passw0rd! \
E2E_FACTORY_PHONE=01000000005   E2E_FACTORY_PASSWORD=Passw0rd! \
npm run test:e2e -- e2e/staff-lifecycle.spec.ts
```

Without those env vars this file skips itself with a message explaining why,
rather than failing — CI/local runs of `npm run test:e2e` are safe by
default and only exercise the public suite unless you deliberately opt in.

## Everything else

```bash
npm run test:e2e        # headless, all files (staff-lifecycle self-skips without env vars)
npm run test:e2e:ui     # Playwright's interactive UI runner, useful while writing new specs
```

`playwright.config.ts` starts its own `next build && next start` on port
3100 automatically when `E2E_BASE_URL` isn't set — no need to start the dev
server yourself for the public suite.
