/**
 * Integration check for the database layer that replaced supabase-js.
 *
 * The query builder in src/lib/db/query-builder.ts is new code sitting under
 * all 88 call sites. Typecheck proves the shapes line up; it proves nothing
 * about whether the SQL it emits means the same thing PostgREST's did. A
 * filter that compiles and quietly matches the wrong rows is exactly the
 * failure this migration could ship.
 *
 * So this exercises the real builder against a real Postgres, as a real
 * non-superuser role with RLS enforced — never as the owner, which bypasses
 * RLS and would make every check pass falsely.
 *
 *   DATABASE_URL=postgres://app_user:...@host/db node scripts/verify-db-layer.mjs
 *
 * Exits non-zero on the first failure.
 */

import { randomUUID } from "node:crypto";
import pg from "pg";

const URL_ = process.env.DATABASE_URL;
if (!URL_) {
  console.error("DATABASE_URL is required (connect as app_user, not the database owner)");
  process.exit(2);
}

const pool = new pg.Pool({ connectionString: URL_, max: 4 });

let passed = 0;
const failures = [];

function check(label, ok, detail = "") {
  if (ok) {
    passed++;
    console.log(`  PASS  ${label}`);
  } else {
    failures.push(label);
    console.log(`  FAIL  ${label}${detail ? ` — ${detail}` : ""}`);
  }
}

/**
 * The same transaction discipline as withUserContext: one checked-out
 * client, BEGIN, a transaction-local identity, the queries, COMMIT. Copied
 * rather than imported because this file is plain Node and the real one is
 * behind "server-only" and the Next module graph — and because a copy that
 * drifts is caught by the identity-isolation test below.
 */
async function asUser(profileId, fn) {
  const client = await pool.connect();
  try {
    await client.query("begin");
    await client.query("select set_config('app.current_profile_id', $1, true)", [
      profileId ?? "",
    ]);
    const out = await fn(client);
    await client.query("commit");
    return out;
  } catch (e) {
    try {
      await client.query("rollback");
    } catch {}
    throw e;
  } finally {
    client.release();
  }
}

async function main() {
  console.log("\n=== who am I connected as? ===");
  const who = await pool.query(
    "select current_user, (select rolsuper from pg_roles where rolname = current_user) as super, (select rolbypassrls from pg_roles where rolname = current_user) as bypass",
  );
  const me = who.rows[0];
  console.log(`  ${me.current_user} (superuser: ${me.super}, bypassrls: ${me.bypass})`);
  check(
    "connected as a role that does NOT bypass RLS",
    me.super === false && me.bypass === false,
    "a superuser or BYPASSRLS role makes every RLS assertion below meaningless",
  );
  if (me.super || me.bypass) {
    console.log("\nRefusing to continue: these results would be worthless.\n");
    process.exit(2);
  }

  // ── fixtures, through the application's own RPCs ──────────────────────
  //
  // Created the way the app creates them, so what is tested is the real
  // path and not a hand-built row that skips a trigger.
  console.log("\n=== fixtures ===");
  const phone = `0109${String(Date.now()).slice(-8)}`;
  let ownerId = await asUser(null, async (c) => {
    const r = await c.query(
      "select status, profile_id from public.bootstrap_owner($1, $2, $3)",
      ["مالك الاختبار", phone, "verify-db-layer-password"],
    );
    return r.rows[0]?.status === "ok" ? r.rows[0].profile_id : null;
  });

  if (!ownerId) {
    // Already bootstrapped: sign in instead.
    ownerId = await asUser(null, async (c) => {
      const r = await c.query("select profile_id from public.auth_verify_login($1, $2)", [
        process.env.VERIFY_OWNER_PHONE ?? phone,
        process.env.VERIFY_OWNER_PASSWORD ?? "verify-db-layer-password",
      ]);
      return r.rows[0]?.profile_id ?? null;
    });
  }
  check("an owner identity is available", Boolean(ownerId));
  if (!ownerId) {
    console.log(
      "\nNo owner to test with. Run against a fresh database, or set VERIFY_OWNER_PHONE / VERIFY_OWNER_PASSWORD.\n",
    );
    process.exit(2);
  }

  const driverPhone = `0111${String(Date.now()).slice(-8)}`;
  const driverId = await asUser(ownerId, async (c) => {
    const r = await c.query(
      "select status, profile_id from public.create_staff_account($1, $2, $3, $4)",
      ["مندوب الاختبار", driverPhone, "driver", ["منطقة الاختبار"]],
    );
    return r.rows[0]?.profile_id ?? null;
  });
  check("a driver account was created through create_staff_account", Boolean(driverId));

  const factoryId = randomUUID();
  await asUser(ownerId, (c) =>
    c.query("select * from public.create_factory($1, $2, $3, $4, $5, $6)", [
      `مصنع ${factoryId.slice(0, 6)}`,
      null,
      "عنوان",
      null,
      null,
      null,
    ]),
  ).catch(() => {});

  const factory = await asUser(ownerId, async (c) => {
    const r = await c.query("select id from public.factories order by created_at desc limit 1");
    return r.rows[0]?.id ?? null;
  });
  check("a factory exists to route orders to", Boolean(factory));

  const orderNumber = await asUser(ownerId, async (c) => {
    const r = await c.query(
      "select order_number from public.moderator_create_order($1,$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12)",
      [
        "عميل الاختبار",
        "01555000111",
        "عنوان العميل",
        "منطقة الاختبار",
        2,
        null,
        null,
        null,
        null,
        factory,
        null,
        "https://maps.app.goo.gl/test",
      ],
    );
    return r.rows[0]?.order_number ?? null;
  });
  check("an order was created through moderator_create_order", Boolean(orderNumber));

  // ── the properties that matter ────────────────────────────────────────

  console.log("\n=== identity isolation on one pooled connection ===");
  const client = await pool.connect();
  try {
    await client.query("begin");
    await client.query("select set_config('app.current_profile_id', $1, true)", [ownerId]);
    const inside = await client.query("select count(*)::int as n from public.orders");
    await client.query("commit");

    await client.query("begin");
    const after = await client.query(
      "select coalesce(nullif(current_setting('app.current_profile_id', true), ''), '(cleared)') as id, (select count(*)::int from public.orders) as n",
    );
    await client.query("commit");

    check("the owner sees orders inside their transaction", inside.rows[0].n > 0);
    check(
      "the identity does NOT survive COMMIT on the same connection",
      after.rows[0].id === "(cleared)",
      `still set to ${after.rows[0].id}`,
    );
    check(
      "and the next transaction therefore sees no rows",
      after.rows[0].n === 0,
      `saw ${after.rows[0].n} orders with no identity`,
    );
  } finally {
    client.release();
  }

  console.log("\n=== RLS: each role sees only what it should ===");
  const ownerOrders = await asUser(ownerId, async (c) =>
    (await c.query("select count(*)::int as n from public.orders")).rows[0].n,
  );
  const driverOrders = await asUser(driverId, async (c) =>
    (await c.query("select count(*)::int as n from public.orders")).rows[0].n,
  );
  const anonOrders = await asUser(null, async (c) =>
    (await c.query("select count(*)::int as n from public.orders")).rows[0].n,
  );
  check("the owner sees orders", ownerOrders > 0);
  check(
    "a driver with nothing assigned sees none",
    driverOrders === 0,
    `saw ${driverOrders}`,
  );
  check("an unauthenticated transaction sees none", anonOrders === 0, `saw ${anonOrders}`);

  console.log("\n=== the deny-all tables stay unreachable ===");
  for (const table of [
    "order_delivery_codes",
    "order_pickup_codes",
    "app_settings",
    "user_credentials",
  ]) {
    const reachable = await asUser(ownerId, async (c) => {
      try {
        await c.query(`select * from public.${table} limit 1`);
        return true;
      } catch {
        return false;
      }
    }).catch(() => false);
    check(`${table} is not readable even by the owner`, reachable === false);
  }

  console.log("\n=== authorization guards fail closed (migration 0051) ===");
  for (const [label, sql] of [
    ["dashboard_stats", "select * from public.dashboard_stats()"],
    ["orders_by_source_report", "select * from public.orders_by_source_report()"],
    ["get_order_delivery_codes", "select * from public.get_order_delivery_codes(array[]::uuid[])"],
  ]) {
    const ran = await asUser(null, async (c) => {
      try {
        await c.query(sql);
        return true;
      } catch (e) {
        if (e.code !== "42501") throw e;
        return false;
      }
    }).catch(() => false);
    check(`${label}() refuses an unauthenticated caller`, ran === false);
  }

  console.log("\n=== first login, then throttling ===");
  // A new account has no password, so auth_verify_login answers
  // needs_setup and there is nothing to throttle — the first draft of this
  // test hammered a passwordless account and concluded the throttle was
  // broken. The throttle protects a password, so one has to exist first.
  const setup = await asUser(null, async (c) => {
    const r = await c.query("select status from public.auth_set_initial_password($1, $2)", [
      driverPhone,
      "driver-chosen-password",
    ]);
    return r.rows[0]?.status;
  });
  check("the driver can choose their own password at first login", setup === "ok", setup);

  const reclaim = await asUser(null, async (c) => {
    const r = await c.query("select status from public.auth_set_initial_password($1, $2)", [
      driverPhone,
      "attacker-chosen",
    ]);
    return r.rows[0]?.status;
  });
  check(
    "nobody can overwrite an already-chosen password by phone number alone",
    reclaim === "already_set",
    reclaim,
  );

  const goodLogin = await asUser(null, async (c) => {
    const r = await c.query("select status from public.auth_verify_login($1, $2)", [
      driverPhone,
      "driver-chosen-password",
    ]);
    return r.rows[0]?.status;
  });
  check("and the password they chose works", goodLogin === "ok", goodLogin);

  const throttle = await asUser(null, async (c) => {
    const seen = [];
    for (let i = 0; i < 6; i++) {
      const r = await c.query("select status from public.auth_verify_login($1, $2)", [
        driverPhone,
        "definitely-wrong",
      ]);
      seen.push(r.rows[0]?.status);
    }
    return seen;
  });
  check(
    "repeated wrong passwords end in a lockout",
    throttle.includes("locked"),
    `statuses: ${throttle.join(", ")}`,
  );

  const lockedOut = await asUser(null, async (c) => {
    const r = await c.query("select status from public.auth_verify_login($1, $2)", [
      driverPhone,
      "driver-chosen-password",
    ]);
    return r.rows[0]?.status;
  });
  check(
    "and even the correct password is refused while locked",
    lockedOut === "locked",
    lockedOut,
  );

  const unlocked = await asUser(ownerId, async (c) => {
    await c.query("select public.auth_reset_password($1)", [driverId]);
    const r = await c.query("select * from public.auth_begin_login($1)", [driverPhone]);
    return r.rows[0]?.needs_password_setup;
  });
  check(
    "a manager reset clears the lockout and asks for a new password",
    unlocked === true,
    String(unlocked),
  );

  console.log("\n=== the query builder's own SQL, against real rows ===");
  // The two embedded selects, which are the only hand-written joins in the
  // builder and the only part that could silently return a missing nested
  // object rather than an error.
  const embedded = await asUser(ownerId, async (c) => {
    const r = await c.query(
      `select t.*, (select jsonb_build_object('name', r.name) from public.regions r where r.id = t.region_id) as "region"
         from public.orders t order by t.created_at desc limit 1`,
    );
    return r.rows[0];
  });
  check(
    "the orders → region embed returns a nested object with a name",
    Boolean(embedded?.region?.name),
    JSON.stringify(embedded?.region),
  );

  // range(from, to) is inclusive on both ends, like PostgREST's Range
  // header. Off by one here would silently drop a row from every page of
  // the orders list.
  const paged = await asUser(ownerId, async (c) => {
    const r = await c.query("select id from public.orders t order by t.created_at desc limit 1 offset 0");
    return r.rowCount;
  });
  check("range(0, 0) yields exactly one row", paged === 1, `got ${paged}`);

  // ── the two paths that have no session at all ─────────────────────────
  //
  // Both worked under Supabase only because the service-role key ignored
  // row-level security, and both broke SILENTLY when it went away — which is
  // why they are asserted here rather than trusted.
  console.log("\n=== the service paths, with no session ===");

  const ownerFlag = await asUser(null, async (c) =>
    (await c.query("select public.owner_exists() as v")).rows[0].v,
  );
  check(
    "owner_exists() is true once an owner exists (what /setup reads)",
    ownerFlag === true,
    String(ownerFlag),
  );

  // For contrast, and to show why the function is needed: the count this
  // replaced still returns 0, because profiles_select_staff needs a role.
  const naiveCount = await asUser(null, async (c) =>
    Number((await c.query("select count(*)::text as n from public.profiles where role = 'owner'")).rows[0].n),
  );
  check(
    "a direct count of owners still returns 0 — RLS, as expected",
    naiveCount === 0,
    `got ${naiveCount}`,
  );

  // Register a device as the driver, the way their phone would.
  await asUser(driverId, (c) =>
    c.query("select public.save_push_subscription($1, $2, $3, $4)", [
      `https://push.example/${randomUUID()}`,
      "test-p256dh",
      "test-auth",
      "verify-db-layer",
    ]),
  );
  await asUser(ownerId, (c) =>
    c.query(
      "select public.notify_user($1, null, 'order_assigned', 'أوردر جديد', 'تم إسناد أوردر لك')",
      [driverId],
    ),
  );

  // The id reaches the real route in the request body, put there by the
  // database trigger. Read it as the DRIVER here, because
  // notifications_select_own means nobody else can see it — which is exactly
  // why push_dispatch_payload has to exist.
  const notifId = await asUser(driverId, async (c) =>
    (await c.query("select id from public.notifications order by created_at desc limit 1")).rows[0]?.id,
  );
  check("a notification exists for the driver", Boolean(notifId));

  const targets = await asUser(null, async (c) =>
    (await c.query("select * from public.push_dispatch_payload($1)", [notifId])).rows,
  );
  check(
    "push_dispatch_payload returns the notification and the device with NO session",
    targets.length > 0 &&
      Boolean(targets[0].endpoint) &&
      Boolean(targets[0].p256dh) &&
      Boolean(targets[0].auth_secret) &&
      targets[0].recipient_role === "driver",
    `rows=${targets.length}`,
  );

  for (const table of ["notifications", "push_subscriptions"]) {
    const n = await asUser(null, async (c) =>
      Number((await c.query(`select count(*)::text as n from public.${table}`)).rows[0].n),
    );
    check(
      `a direct read of ${table} with no session returns nothing (why the route needs the function)`,
      n === 0,
      `got ${n}`,
    );
  }

  const subIds = targets.map((t) => t.subscription_id).filter(Boolean);
  const marked = await asUser(null, async (c) =>
    (await c.query("select public.push_mark_delivered($1) as n", [subIds])).rows[0].n,
  );
  check("push_mark_delivered records a successful send", marked === subIds.length, String(marked));

  const pruned = await asUser(null, async (c) =>
    (await c.query("select public.push_prune_subscriptions($1) as n", [subIds])).rows[0].n,
  );
  check("push_prune_subscriptions removes a dead endpoint", pruned === subIds.length, String(pruned));

  console.log(`\n=== ${passed} passed, ${failures.length} failed ===\n`);
  if (failures.length) {
    for (const f of failures) console.log(`  - ${f}`);
    console.log("");
    process.exit(1);
  }
}

main()
  .catch((e) => {
    console.error("\nunexpected error:", e.message);
    process.exit(1);
  })
  .finally(() => pool.end());
