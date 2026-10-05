# Handover: transferring ownership to the customer

Everything that has to change hands, in the order it has to happen, so that
afterwards the customer owns the code, the deployment and the database
outright — and nobody who worked on the build can still reach any of it.

Two things make this different from a normal handover. **The order matters**:
transfer GitHub before Vercel, or the deployment loses its connection to the
repository. And **every secret anyone has seen has to be replaced**, not just
re-shared. A credential that has been in a chat window, a terminal history or
a screenshot is not a credential any more.

Budget about 90 minutes with the customer present. Most of it is waiting for
confirmation emails.

---

## 0. Before you start

**The customer needs accounts first.** They cannot be invited to something
they have no login for. Ask them to create, with an email address *they*
control and that will outlive any one employee — a shared `ops@` or
`it@` address rather than someone's personal one:

- a GitHub account, and ideally a GitHub **organisation** to hold the repo
- a Vercel account
- a Neon account

Turn on two-factor authentication on all three now rather than later. These
three logins are the system; whoever holds them holds it.

**Take a backup you keep.** Not for them — for you, in case a step goes
sideways mid-transfer:

- Neon → your project → **Backups**, take a manual one, and confirm it
  completed.
- A full schema and data export via the **direct** connection string if you
  have `pg_dump` available.
- Note the current `git rev-parse HEAD` so you can prove what was handed over.

**Agree what is being transferred.** Worth writing down in an email before
you start, because "the system" means different things to different people:
the repository and its history, the running deployment, the database and its
contents, the domain, and who pays for what from which date. Also agree the
support period, if any, and that you will no longer have access afterwards —
which is the point, but it means "can you just quickly fix…" stops being
possible.

---

## 1. GitHub — the repository

The repo is currently `TechHeroesAcademy/order-system`.

### Clean it up first

```bash
git log --oneline -1          # note the commit being handed over
git status                    # must be clean
```

Check nothing secret was ever committed. The migration files were written to
avoid this deliberately, but check rather than assume:

```bash
git log -p --all -S 'VAPID_PRIVATE_KEY' -- . | head
git log -p --all -S 'postgresql://' -- . | head
git log --all --diff-filter=A --name-only -- '*.env*'
```

If any of those return a real value, it is in the history forever and
rewriting history after transfer is the customer's problem. Rotating the
affected secret (section 5) is the fix; the history is cosmetic after that.

### Transfer

Settings → General → **Danger Zone → Transfer ownership**. Enter the
customer's account or organisation name and confirm.

A few things worth knowing before you press it:

- Transferring **out of an organisation** needs organisation owner rights,
  not just admin on the repository.
- The customer must **accept** the transfer. Until they do, nothing moves.
- Issues, pull requests, stars, watchers and the full commit history move with
  it. The old URL redirects to the new one, so existing clones keep working —
  which is convenient and also means the redirect is not a security boundary.
- **Forks do not move.** Anyone who forked it keeps their copy, including any
  secret that was ever committed. Check the fork list before transferring.
- GitHub Actions secrets do **not** transfer. There are none in this
  repository; confirm with Settings → Secrets and variables.

### Afterwards

- Remove yourself as a collaborator (or let the customer do it, which is
  cleaner — they should see the access list go empty but for them).
- **Revoke every personal access token** you used against this repo: your
  GitHub account → Settings → Developer settings → Personal access tokens.
  Both the fine-grained token used for pushes and the older classic one.
  Revoke, do not just delete the local copy.
- Check Settings → Deploy keys and Settings → Integrations for anything left
  over.

---

## 2. Vercel — the deployment

Do this **after** GitHub, so the project reconnects to a repository the
customer already owns.

There are two routes. Transferring the project keeps the deployment history
and the domain configuration; a fresh import is simpler but starts the
history over and needs the domain re-pointed.

### Route A — transfer the project (preferred)

1. The customer creates a Vercel **team** (Hobby accounts cannot receive a
   transfer).
2. Your project → Settings → General → **Transfer Project**, choose their
   team.
3. They accept.

**Environment variables do not come across reliably, and you should assume
they do not.** Treat section 5 as mandatory: the customer re-enters every one
of them with new values. Do not read your existing values out to them.

After transfer, in their team: Settings → Git → confirm it is connected to
their repository, and reconnect if not.

### Route B — fresh import

1. Customer's team → Add New → Project → import their repository.
2. They add all the environment variables from section 5.
3. Deploy, confirm it works on the `*.vercel.app` URL.
4. Move the domain (section 4).
5. Delete your old project — **last**, only once theirs is confirmed working,
   because deleting it releases the domain.

### Either route

- Confirm the production branch is `main`.
- Check Settings → Deployment Protection. If preview deployments are
  password-protected or team-only, say so — one of the two projects in this
  account had that set, and it looks exactly like a broken deploy.
- Remove yourself from their team once they confirm the site is up.

---

## 3. Neon — the database

Neon projects transfer between **organisations**, so the customer needs a Neon
organisation, not just a personal account.

### Route A — transfer the project

1. Customer creates a Neon organisation.
2. Your project → Settings → **Transfer to organisation**.
3. They accept, then **rotate the `app_user` password immediately** (section
   5) and update `DATABASE_URL` and `DATABASE_URL_UNPOOLED` in Vercel.

The data comes with it. Nothing has to be exported or re-imported.

### Route B — their own project, data copied

Only if transfer is unavailable on the plan, or if they want a clean project.

1. Customer creates the project, in the region nearest their Vercel
   deployment.
2. They run the four files from `db/bundled/` in order — `DEPLOYMENT.md`
   section 2. **Do not hand them a `pg_dump` of your schema instead:** the
   bundles are what was tested, and a dump taken with the wrong role carries
   ownership and grants that will not match.
3. Copy the data, if they want the existing orders, via the **direct**
   connection strings, in foreign-key order:
   `profiles → regions → driver_regions → factories → manager_factories →
   orders → order_history → order_messages → order_delivery_codes →
   order_pickup_codes → notifications → push_subscriptions → app_settings`
   and `user_credentials` last.
   Profile ids are plain UUIDs and every foreign key points at
   `profiles.id`, so this is a straight copy with nothing to remap.
4. Verify before pointing the app at it: row count per table equal on both
   sides, and zero orphan foreign keys.

**Or start empty**, which is often the right answer at a handover:
`db/maintenance/reset_all_data.sql` empties every account and order
while keeping the schema and the push configuration, then the customer creates
their own first owner at `/setup`.

### Either route

- Check the **backup retention** on their plan matches what they would want to
  be able to restore.
- Confirm `DATABASE_URL` points at `app_user` and not the Neon owner role:
  ```sql
  select current_user, rolsuper, rolbypassrls from pg_roles where rolname = current_user;
  ```
  Expect `app_user`, `f`, `f`. If it says otherwise, the row-level security
  model is switched off, and every "permission denied" shortcut that gets
  taken later will make it worse.

---

## 4. The domain

If the system runs on a custom domain, the customer should own the domain
registration too — otherwise you still hold the one thing that points at
everything else.

1. Transfer the domain at the registrar (customer initiates; needs the auth
   code from you, and the domain must be older than 60 days).
2. Add the domain to **their** Vercel project; Vercel shows the DNS records.
3. Update the records at the registrar.
4. Wait for the certificate to issue, then confirm `https://` works.
5. **Update `push_endpoint_url`** in `app_settings` if the domain changed, or
   push stops silently:
   ```sql
   update public.app_settings
      set value = 'https://NEW-DOMAIN/api/push/dispatch'
    where key = 'push_endpoint_url';
   ```

Keep the old domain pointed at the new deployment for a while if drivers have
it bookmarked or installed on their Home Screens.

---

## 5. Secrets — every one of them gets replaced

This is the part that is easy to skip and the only part that is irreversible
if skipped. Anything that has been in a chat, a terminal, a screenshot or a
document is compromised by definition, regardless of who was in the room.

**The customer generates these themselves and never shares them back.** Your
part is to say what each one is and watch them replace it.

| Secret | How | Effect |
|---|---|---|
| `app_user` database password | `alter role app_user with login password '...';` then update both `DATABASE_URL`s in Vercel | Old connection strings stop working at once |
| `SESSION_SECRET` | `select encode(gen_random_bytes(48), 'base64');` | Signs everyone out — expected, and worth doing deliberately |
| GitHub tokens | Revoke, in your account | — |

### VAPID keys and the push secret — read this before touching them

`VAPID_PRIVATE_KEY`, `NEXT_PUBLIC_VAPID_PUBLIC_KEY` and `PUSH_WEBHOOK_SECRET`
are different from the rest, because replacing the VAPID pair **silently
invalidates every device anyone has already registered**. Nobody gets a
notification again until each person re-enables it on their own phone, and
nothing anywhere reports an error.

`PUSH_WEBHOOK_SECRET` can be rotated on its own, safely, and should be. It
must be changed in **two places at once** — the Vercel variable and the
`app_settings` row — and push stops between the two:

```sql
update public.app_settings
   set value = 'THE NEW SECRET, MATCHING VERCEL EXACTLY'
 where key = 'push_webhook_secret';
```

For the VAPID pair, the honest options are:

- **Rotate** — correct if anyone outside the customer's team has seen the
  private key. Plan it: new keys, redeploy, then walk every driver and manager
  through re-enabling notifications on their phone. Do it when someone is
  available to help them.
- **Keep** — defensible if the key has stayed inside the team. The worst a
  leaked VAPID private key allows is sending push notifications to devices
  already subscribed to this app. That is unpleasant — a convincing fake "new
  order" — but it reads no data and grants no access.

Decide it explicitly and write down which you chose. The failure mode is
nobody deciding, and the keys quietly staying as they are with no one aware
that is a decision.

---

## 6. Accounts inside the system

The application's own logins are separate from the three platform accounts
and are just as important.

1. The customer creates their own owner account. On a fresh database that is
   `/setup`; on an existing one, from الفريق while you are still signed in.
2. They confirm they can sign in and reach **الفريق**.
3. **Delete every account belonging to you or anyone else leaving**, from
   الفريق. The system refuses to delete the last active owner and refuses to
   let anyone delete their own account, so the customer does this — which is
   the right way round.
4. For staff who stay: nothing to do. Nobody's password is known to anyone,
   including you. If you want certainty, the customer can press reset on each
   row and each person chooses a new password at their next login.

---

## 7. What else to hand over

**In the repository.** `README.md` for the architecture, `DEPLOYMENT.md` for
standing it up from nothing, `HANDOVER.md` for day-to-day use in Arabic,
`db/RUNBOOK.md` for why the
database is arranged the way it is.

**The operational files**, which the customer will need one day and will not
find under pressure:

- `db/maintenance/verify_role_guards.sql` — the security check. Tell
  them to run it after any database change. It is the one that catches an
  authorization guard falling open.
- `db/maintenance/reset_all_data.sql` — empties the system.
- `db/bundled/` — the four files that build the schema from nothing.
- `scripts/verify-db-layer.mjs` — 26 checks against a real database.

**Written down somewhere that is not a chat window:** which Neon region, which
Vercel team, who holds the domain, where the VAPID keys are stored, and the
decision you made in section 5.

**Point out two things in particular**, because they are the two that will
bite otherwise:

1. **Region names are typed, not picked from a list**, and orders are matched
   to drivers by that text. "أكتوبر" and "اكتوبر" are different areas to the
   system. One spelling per area, consistently.
2. **Never point `DATABASE_URL` at the Neon owner role.** It will look like it
   fixes a permissions problem. What it actually does is turn off every
   row-level security policy, so a driver can read every order and every
   customer's phone number.

---

## 8. Final check, together

Do this with the customer watching, on their accounts, before you leave:

- [ ] Repository shows under their account; your access is gone
- [ ] Vercel project under their team, production deploy green
- [ ] Neon project under their organisation; `DATABASE_URL` is `app_user`
- [ ] Domain resolves over HTTPS, certificate valid
- [ ] `verify_role_guards.sql` → 10 PASS
- [ ] They sign in as their own owner account
- [ ] A moderator creates an order, a driver delivers it on a real phone,
      the push arrives
- [ ] `/track` finds an order by number plus customer phone
- [ ] Your accounts are deleted from الفريق
- [ ] Every secret in section 5 replaced, or the VAPID decision recorded
- [ ] Your GitHub tokens revoked
- [ ] Billing on their payment method for Vercel and Neon

Then confirm in writing what was transferred, on what date, at which commit,
and what support arrangement follows. A short email is enough and it prevents
the common disagreement a month later about what "handed over" included.
