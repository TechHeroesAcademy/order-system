# Setting the system up on a new GitHub, Vercel and Neon account

A plain checklist for standing up a second, fully independent copy of the
system — new code repository, new hosting, new database, sharing nothing with
the old one.

Allow about 45 minutes. Nothing here needs programming. One step needs a
terminal, and step 3 says exactly what to type.

If instead you want to hand the existing system over to someone else rather
than build a new one, use `TRANSFER.md` — that moves what you already have,
including the live data.

---

## Before you start

Create the three accounts first, so you are not signing up halfway through:

- **GitHub** — github.com. Free.
- **Vercel** — vercel.com. Sign in with the new GitHub account, not an email.
  That connects them automatically and saves a step later.
- **Neon** — neon.tech. Free.

You will also need the project files. Either you already have the folder on
your computer, or you have access to the current GitHub repository.

Keep a notes file open. You will collect six values along the way and paste
them into Vercel in step 5.

---

## Step 1 — Put the code in the new GitHub account

Pick whichever route fits. Route A keeps the old copy; route B does not.

### Route A — you have the project folder on your computer

On github.com, click **+** (top right) → **New repository**. Name it
`order-system`, choose **Private**, and do **not** tick any of the "add a
README / .gitignore / licence" boxes. Click **Create repository**.

GitHub then shows you a page of commands. Ignore them and use these instead,
run from inside the project folder in a terminal. Replace `NEW-USERNAME`:

```bash
git remote remove origin
git remote add origin https://github.com/NEW-USERNAME/order-system.git
git branch -M main
git push -u origin main
```

GitHub will ask for a username and password. The password is **not** your
GitHub password — it is a token. Get one at github.com → your picture →
**Settings** → **Developer settings** → **Personal access tokens** → **Tokens
(classic)** → **Generate new token (classic)**, tick **repo**, generate, and
copy it. Paste that as the password.

### Route B — move the existing repository across

Simpler, but the old account stops having it.

On the current repository: **Settings** → scroll to the bottom → **Transfer
ownership**. Type the new account's username, confirm, and accept the transfer
from the new account's email.

### Either way

Check the new repository shows a `src` folder, a `neon` folder and a
`package.json`. If it does, this step is done.

> The "Import a repository" option on GitHub does not work here. It can only
> reach repositories that are public on the internet, and yours is private.

---

## Step 2 — Create the database

1. On neon.tech, click **New project**. Pick the region closest to you —
   Frankfurt (`eu-central-1`) is the nearest to Egypt. Leave everything else
   as it comes.

2. Open **SQL Editor** from the left sidebar. You are going to paste four
   files, one at a time, in order. They are in the project under
   `db/bundled/`:

   | | File | What it builds |
   |---|---|---|
   | 1 | `part1_of_4.sql` | the tables and the core order workflow |
   | 2 | `part2_of_4.sql` | chat, codes, reports, factories, distribution |
   | 3 | `part3_of_4.sql` | driver field orders, repeat-customer check |
   | 4 | `part4_of_4.sql` | passwords and login, the notification queue |

   Open a file, select everything, paste it into the editor, press **Run**,
   and **wait for it to finish** before starting the next one. Each takes a
   few seconds.

   **Run them in order and one at a time.** Parts 2 and 3 cannot share a run —
   part 2 adds a new value that part 3 uses, and Postgres will not allow both
   in one go. If you lose your place, re-running a part is harmless.

3. Check it worked. Paste this and run it:

   ```sql
   select count(*) as tables from pg_class c
     join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relkind = 'r';
   ```

   You should get **15**. If you get fewer, a part did not finish — run
   `db/maintenance/check_schema_parts.sql`, which tells you which one.

4. Give the application its own database password. Make up a long random one
   and run:

   ```sql
   alter role app_user with login password 'PUT-A-LONG-RANDOM-PASSWORD-HERE';
   ```

   **Write that password in your notes.** You need it in the next step.

   `app_user` is deliberately not the account Neon gave you. It cannot see
   past the system's security rules, so even if the website were compromised,
   it still only shows each person what their role allows. Never swap it for
   the Neon owner account to make an error go away — that works by switching
   the security off, and nothing will look wrong.

5. Build the connection string. In Neon, click **Connect** (or **Connection
   Details**) on the project dashboard and copy the string it offers. Make
   sure you take the **pooled** one — its address has `-pooler` in it. It
   looks like this:

   ```
   postgresql://neondb_owner:SOMETHING@ep-xxxx-pooler.eu-central-1.aws.neon.tech/neondb?sslmode=require
   ```

   Now replace the part between `//` and `@` with `app_user` and the password
   you just set, keeping Neon's address exactly as it gave it:

   ```
   postgresql://app_user:YOUR-PASSWORD@ep-xxxx-pooler.eu-central-1.aws.neon.tech/neondb?sslmode=require
   ```

   If the string ends with `&channel_binding=require`, delete that part. Keep
   `?sslmode=require`.

   **Save this in your notes as `DATABASE_URL`.**

---

## Step 3 — Make the secrets

Four values, and they must be new. Do not copy them from another installation:
two separate systems sharing a signing key is two systems that can forge each
other's logins.

**The login signing key.** In the Neon SQL Editor, run this and copy the one
value it returns:

```sql
select encode(gen_random_bytes(48), 'base64');
```

Save it as `SESSION_SECRET`.

**The notification keys.** In a terminal, inside the project folder:

```bash
node scripts/generate-push-keys.mjs
```

It needs nothing installed beyond Node — no `npm install`. It prints four
lines, ready to paste: `NEXT_PUBLIC_VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY`,
`PUSH_WEBHOOK_SECRET`, and a `VAPID_SUBJECT` line with a placeholder email
you should change to your own. Save all of them.

**Generate these once and keep them for ever.** Replacing the notification
keys later does not reset anything — it silently unregisters every phone that
had notifications working, with no error and no warning. Each person then has
to turn them on again on their own device. Put them in a password manager now.

---

## Step 4 — Collect your six values

Before touching Vercel, check your notes has all six:

| Name | Where it came from |
|---|---|
| `DATABASE_URL` | step 2.5 — the pooled string with `app_user` in it |
| `SESSION_SECRET` | step 3 — the SQL query |
| `NEXT_PUBLIC_VAPID_PUBLIC_KEY` | step 3 — the script |
| `VAPID_PRIVATE_KEY` | step 3 — the script |
| `PUSH_WEBHOOK_SECRET` | step 3 — the script |
| `VAPID_SUBJECT` | you write it: `mailto:your@email.com` |

`VAPID_SUBJECT` is a contact address for whoever runs the system. Apple and
Google require it so they can reach a human if the notifications misbehave.
Use an address someone reads. It is not secret.

---

## Step 5 — Put it online

1. On vercel.com, click **Add New** → **Project**. Your new GitHub repository
   should be listed; click **Import**. If it is not listed, click **Adjust
   GitHub App Permissions** and give Vercel access to it.

2. Do not change the framework or build settings. Vercel detects them.

3. Open **Environment Variables** and add all six from step 4. For each one,
   paste the name and the value, and make sure **Production**, **Preview** and
   **Development** are all ticked. Missing an environment is the most common
   mistake here, and it fails later with an error that points somewhere else.

4. Click **Deploy** and wait for it to go green.

5. Find your address. **Settings** → **Domains**. Take the clean one without
   random letters in the middle — something like
   `order-system-xyz.vercel.app`. The long one with random characters is a
   preview address sitting behind Vercel's own login page, and it will look
   broken.

---

## Step 6 — Tell the database where the site lives

The database decides when a notification is due, so it needs the address and
the same secret. Back in the Neon SQL Editor, with your real domain and your
real `PUSH_WEBHOOK_SECRET`:

```sql
insert into public.app_settings (key, value) values
  ('push_endpoint_url', 'https://YOUR-DOMAIN/api/push/dispatch'),
  ('push_webhook_secret', 'YOUR-PUSH-WEBHOOK-SECRET')
on conflict (key) do update set value = excluded.value;
```

The secret must match what is in Vercel **character for character**. If it
does not, every notification is refused and nothing is ever delivered, with
nothing in any log to explain why. It is the single most common reason
notifications do not work.

If you later put a custom domain on the site, come back and run this again
with the new address.

---

## Step 7 — Create the first account

Open `https://YOUR-DOMAIN/setup`.

Enter a name, a phone number as `01xxxxxxxxx`, and a password you choose. It
creates the owner account and signs you in.

This page works only while no owner exists and stops the moment you submit, so
nobody else can use it afterwards.

Use a phone number you really have. It is the login, and there is deliberately
no email reset.

---

## Step 8 — Fill in the team, in this order

Open **الفريق**. The order matters.

1. **المصانع first.** Picking a factory is required when creating an order, so
   while the list is empty nobody can create one. Paste each factory's Google
   Maps share link into the موقع field and the pin places itself.

2. **الموظفون next.** Name, phone, role, and for drivers the areas they cover.
   You never type anyone's password — each person enters their phone number on
   the login page the first time and chooses their own.

   Areas are typed, not picked from a list. **Use one spelling per area and
   keep to it**, because orders are matched to drivers by that exact text.
   "شبرا" and "شبرا الخيمة" are two different areas as far as the system is
   concerned.

3. **Managers → factories last.** A manager with no factory assigned gets no
   chat notifications.

---

## Step 9 — Turn notifications on, per person and per phone

Notifications are per device, not per account. Each person signs in, opens
their home page, and presses the button on the notifications card.

On **iPhone** this only works if the app is installed to the Home Screen:
Share → **Add to Home Screen**, then open it from that icon. Safari in an
ordinary tab cannot receive notifications at all.

On **Android** it works in Chrome directly.

Who gets what: drivers are told when an order is assigned to them, and about
chat on their orders. Owners and moderators are told about chat only on orders
for a factory they manage — so a manager with no factory assigned gets
nothing.

---

## Step 10 — Check it actually works

Walk one order through from start to finish. Use a real phone for the driver
part.

- [ ] A moderator creates an order. It needs a Google Maps link for the
      customer and a factory.
- [ ] The success screen shows an **order number** and **two 4-digit codes**.
      If any of those three is blank, stop and say so — it means something is
      wrong rather than empty.
- [ ] The order appears under **التوزيع**, grouped by area, with a suggested
      driver. The manager approves it.
- [ ] The driver signs in on their phone and presses through every step to
      delivered, using the pickup and delivery codes.
- [ ] The notification arrives on the driver's phone and the bell shows it.
- [ ] Creating a second order for the **same customer phone number** pops a
      confirmation saying which number order this is for that customer.
- [ ] `/track` finds an order from its number plus the customer's phone.

Then two security checks, because this is the part nobody notices is wrong.

In the Neon SQL Editor:

```sql
select current_user, rolsuper, rolbypassrls
from pg_roles where rolname = current_user;
```

Run this while connected as the application would be. You want
`app_user`, `f`, `f`. Anything else means `DATABASE_URL` points at the wrong
account and the security rules are switched off.

Then paste the whole of `db/maintenance/verify_role_guards.sql` and run
it. Ten checks, all should say PASS. This is the one that catches a permission
check falling open.

Finally, sign out and open `/owner`. It must send you to the login page.

---

## If something does not work

| What you see | What it usually is |
|---|---|
| Every page fails, or `/setup` says the system is already set up | `DATABASE_URL` is wrong, or `app_user` has no password. Redo steps 2.4 and 2.5. |
| The site will not start, or previews fail but production works | A variable is missing, or is not ticked for all three environments. Recheck step 5.3. |
| Notifications never arrive | Almost always the secret in step 6 not matching Vercel exactly. Also check each phone turned them on, and that iPhones are opening the Home Screen install. |
| An order saves but the number and codes are blank | The deploy is older than the fix for that. Redeploy from the newest code. |
| Nobody can create an order | No factories yet. Add them in الفريق → المصانع. |
| Orders are not matched to drivers | Area spellings do not match between the order and the driver's coverage. |
| The page is full of random letters and asks for a Vercel login | You are on a preview address. Use the clean domain from step 5.5. |

For the notification queue specifically: the database writes each pending
notification into `public.push_outbox`, and the site empties that queue. To see
what happened to one:

```sql
select id, created_at, attempts, delivered_at, last_error
from public.push_outbox
order by id desc limit 20;
```

`delivered_at` filled in means it was sent. Blank with a `last_error` tells you
why it failed, per attempt.

---

## Afterwards

**Back it up.** Neon keeps point-in-time restore according to your plan. Check
the window is as long as you would want, and take a manual export before any
change to the database structure.

**Keep the secrets.** All six values from step 4, plus the `app_user` password
and your Neon login, belong in a password manager. The notification private key
cannot be recovered or regenerated without cutting every phone off.

**Starting the data over.** `db/maintenance/reset_all_data.sql` empties
every account and order while keeping the structure and the notification
settings. It refuses to run until you edit one line in it, on purpose.

**Adding changes later.** New database changes go in `db/migrations/`,
then re-run `node scripts/build-neon-bundle.mjs` to rebuild the four files in
`db/bundled/`. Apply those with Neon's **direct** connection string, not the
pooled one.
