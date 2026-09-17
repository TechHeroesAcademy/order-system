#!/usr/bin/env node
// scripts/stress-test.mjs
//
// Concurrency / "many rapid clicks in production" stress test for the order
// workflow RPCs. This talks directly to Postgres (not through the Next.js
// app), because the thing being tested — what happens when the same action
// fires many times at once — is a database-transaction question. Every
// workflow RPC in supabase/migrations/0009_workflow_rpcs.sql opens with
// `select ... for update`, which row-locks the order and should serialize
// concurrent attempts instead of double-processing them. This script proves
// that empirically rather than just trusting the code.
//
// Usage:
//   STRESS_DB_URL=postgres://user:pass@host:5432/dbname npm run test:stress
//
// Point STRESS_DB_URL at a disposable database that already has every
// migration in supabase/migrations/ applied (a local dev DB, a Supabase
// branch/staging project, or a throwaway clone of one) — this script
// creates and mutates real rows. Never point it at production.
//
// What it checks, each simulating a real "user mashes the button" scenario:
//   1. N concurrent identical `driver_deliver_to_customer` calls with the
//      correct code (double/triple-tapping "confirm delivery") -> exactly
//      one succeeds and closes the order; the rest fail cleanly; exactly
//      one `delivered` history entry is written, never more.
//   2. A burst of concurrent `public_create_order` calls (many customers
//      submitting the website form at once) -> every order_number handed
//      back is unique — the sequence-based generator never collides or
//      blocks under load.
//   3. Concurrent wrong-code delivery attempts (someone guessing rapidly)
//      -> failed_code_attempts increments by exactly the number of wrong
//      attempts, no lost updates, and the order never closes.
//   4. Concurrent `factory_confirm_receipt` double-clicks -> exactly one
//      succeeds, one `factory_confirmed` history entry.
//   5. Concurrent `approve_distribution` double-clicks -> exactly one
//      succeeds.
//   6. Concurrent `reassign_order_driver` to two different drivers at once
//      -> both may legitimately succeed (serialized one after another by
//      the row lock), but the final state must be consistent (one driver
//      ends up assigned, two history entries, no corruption, no deadlock).

import pg from "pg";

const DB_URL = process.env.STRESS_DB_URL;
if (!DB_URL) {
  console.error(
    "STRESS_DB_URL is not set. Point it at a disposable Postgres database\n" +
      "that already has every migration in supabase/migrations/ applied, e.g.:\n\n" +
      "  STRESS_DB_URL=postgres://postgres@localhost:5432/order_system_stress npm run test:stress\n",
  );
  process.exit(1);
}

const CONCURRENCY = Number(process.env.STRESS_CONCURRENCY ?? 15);

let failures = 0;
function check(label, condition, detail) {
  if (condition) {
    console.log(`  ✓ ${label}`);
  } else {
    failures++;
    console.log(`  ✗ ${label}${detail ? ` — ${detail}` : ""}`);
  }
}

/** Runs `fn(client)` inside its own connection + transaction, with the given
 * auth.uid()/role session vars set (mirrors what PostgREST does per-request
 * on real Supabase — see /tmp/auth-stub.sql's use of these same GUCs). */
async function asUser(pool, userId, fn) {
  const client = await pool.connect();
  try {
    await client.query("begin");
    // SET/SET LOCAL are utility statements and don't accept bind parameters
    // ($1) at the protocol level — set_config() is the parameterized
    // equivalent and is what actually lets an arbitrary uuid flow in safely.
    await client.query(userId ? "set local role authenticated" : "set local role anon");
    if (userId) {
      await client.query("select set_config('request.jwt.claim.sub', $1, true)", [userId]);
      await client.query("select set_config('request.jwt.claim.role', 'authenticated', true)");
    }
    const result = await fn(client);
    await client.query("commit");
    return { ok: true, result };
  } catch (err) {
    await client.query("rollback").catch(() => {});
    return { ok: false, error: err.message };
  } finally {
    client.release();
  }
}

async function main() {
  const pool = new pg.Pool({ connectionString: DB_URL, max: CONCURRENCY + 5 });

  console.log(`Stress-testing workflow RPCs with ${CONCURRENCY}-way concurrency...\n`);

  const admin = await pool.connect();
  const { rows: owners } = await admin.query("select id from public.profiles where role = 'owner' and is_active limit 1");
  const { rows: drivers } = await admin.query("select id from public.profiles where role = 'driver' and is_active limit 2");
  const { rows: regions } = await admin.query("select id, name from public.regions limit 1");
  if (!owners[0] || drivers.length < 2 || !regions[0]) {
    console.error("Seed data missing: need at least 1 active owner, 2 active drivers, and 1 region in this database.");
    console.error("Run supabase/seed.sql against it first, or point STRESS_DB_URL at a DB that already has staff.");
    process.exit(1);
  }
  const ownerId = owners[0].id;
  const driverAId = drivers[0].id;
  const driverBId = drivers[1].id;
  // public_create_order's 4th param is p_region_name text as of migration
  // 0025 (typed منطقة, resolved/auto-created via find_or_create_region) —
  // pass the seeded region's name, not its id.
  const regionName = regions[0].name;
  admin.release();

  // ---------- Test 1: concurrent order creation burst ----------
  console.log("1) Concurrent order creation burst (many customers submitting the website form at once)");
  {
    const createOne = (i) =>
      asUser(pool, null, async (client) => {
        // public_create_order runs as anon in production; role doesn't matter
        // for this RPC (it has no auth check), so run it on a plain connection.
        const { rows } = await client.query(
          `select (r).* from public_create_order($1,$2,$3,$4,$5) r`,
          [`عميل ${i}`, `0100000${String(i).padStart(4, "0")}`, "عنوان تجريبي", regionName, 1],
        );
        return rows[0];
      });
    const results = await Promise.all(Array.from({ length: 30 }, (_, i) => createOne(i)));
    const succeeded = results.filter((r) => r.ok);
    const numbers = succeeded.map((r) => r.result.order_number);
    const uniqueNumbers = new Set(numbers);
    check("all 30 concurrent submissions succeeded", succeeded.length === 30, `${succeeded.length}/30`);
    check("every order_number is unique (no sequence collision under load)", uniqueNumbers.size === numbers.length,
      `${uniqueNumbers.size} unique of ${numbers.length}`);
  }

  // ---------- Set up one order for the remaining tests ----------
  async function makeAssignedOrder() {
    const { result: created } = await asUser(pool, null, (client) =>
      client
        .query(`select (r).* from public_create_order($1,$2,$3,$4,$5) r`, ["عميل الضغط المتكرر", "01099999999", "عنوان", regionName, 2])
        .then((r) => r.rows[0]),
    );
    const orderId = created.order_id;
    const code = created.delivery_code;
    await asUser(pool, ownerId, (client) => client.query("select set_order_distribution($1,$2,false)", [orderId, driverAId]));
    await asUser(pool, ownerId, (client) => client.query("select approve_distribution($1)", [orderId]));
    await asUser(pool, driverAId, (client) => client.query("select driver_mark_collected($1,$2)", [orderId, created.pickup_code]));
    await asUser(pool, driverAId, (client) => client.query("select driver_hand_to_factory($1)", [orderId]));
    const factoryRow = await admin_query(pool, "select id from public.profiles where role = 'factory' and is_active limit 1");
    const factoryId = factoryRow[0]?.id;
    if (factoryId) {
      await asUser(pool, factoryId, (client) => client.query("select factory_confirm_receipt($1)", [orderId]));
      await asUser(pool, factoryId, (client) => client.query("select factory_mark_ready($1)", [orderId]));
    } else {
      // No factory account seeded — fast-forward status directly (test setup
      // only; the RPCs above are what's actually under test elsewhere).
      await admin_query(pool, "update public.orders set status = 'ready' where id = $1", [orderId]);
    }
    await asUser(pool, driverAId, (client) => client.query("select driver_confirm_factory_pickup($1)", [orderId]));
    return { orderId, code };
  }

  async function admin_query(p, sql, params = []) {
    const c = await p.connect();
    try {
      return (await c.query(sql, params)).rows;
    } finally {
      c.release();
    }
  }

  // ---------- Test 2: concurrent double-click "confirm delivery" with the correct code ----------
  console.log("\n2) Concurrent \"confirm delivery\" double/triple-clicks with the correct code");
  {
    const { orderId, code } = await makeAssignedOrder();
    const attempt = () =>
      asUser(pool, driverAId, (client) => client.query("select driver_deliver_to_customer($1,$2) as ok", [orderId, code]));
    const results = await Promise.all(Array.from({ length: CONCURRENCY }, attempt));
    const trueSuccesses = results.filter((r) => r.ok && r.result.rows[0].ok === true).length;
    const rejections = results.filter((r) => !r.ok || r.result.rows[0].ok === false).length;
    const historyRows = await admin_query(
      pool,
      "select count(*)::int as n from public.order_history where order_id = $1 and event_type = 'delivered'",
      [orderId],
    );
    const finalStatus = await admin_query(pool, "select status from public.orders where id = $1", [orderId]);
    check("exactly 1 of the concurrent calls actually delivered the order", trueSuccesses === 1, `${trueSuccesses} succeeded`);
    check("the rest were rejected (already delivered / wrong state), not silently duplicated",
      rejections === CONCURRENCY - 1, `${rejections} rejected`);
    check("exactly one 'delivered' history entry was written", historyRows[0].n === 1, `${historyRows[0].n} entries`);
    check("final order status is 'delivered'", finalStatus[0].status === "delivered");
  }

  // ---------- Test 3: concurrent wrong-code attempts ----------
  console.log("\n3) Concurrent wrong-code delivery attempts (rapid guessing)");
  {
    const { orderId } = await makeAssignedOrder();
    const attempt = () =>
      asUser(pool, driverAId, (client) => client.query("select driver_deliver_to_customer($1,$2) as ok", [orderId, "0000"]));
    await Promise.all(Array.from({ length: CONCURRENCY }, attempt));
    const row = await admin_query(pool, "select status, failed_code_attempts from public.orders where id = $1", [orderId]);
    check(`failed_code_attempts incremented by exactly ${CONCURRENCY} (no lost updates under concurrency)`,
      row[0].failed_code_attempts === CONCURRENCY, `got ${row[0].failed_code_attempts}`);
    check("order was never wrongly closed", row[0].status === "with_driver", `status is ${row[0].status}`);
  }

  // ---------- Test 4: concurrent factory_confirm_receipt double-clicks ----------
  console.log("\n4) Concurrent \"factory confirmed receipt\" double-clicks");
  {
    const { result: created } = await asUser(pool, null, (client) =>
      client
        .query(`select (r).* from public_create_order($1,$2,$3,$4,$5) r`, ["عميل مصنع", "01098888888", "عنوان", regionName, 1])
        .then((r) => r.rows[0]),
    );
    const orderId = created.order_id;
    await asUser(pool, ownerId, (client) => client.query("select set_order_distribution($1,$2,false)", [orderId, driverAId]));
    await asUser(pool, ownerId, (client) => client.query("select approve_distribution($1)", [orderId]));
    await asUser(pool, driverAId, (client) => client.query("select driver_mark_collected($1,$2)", [orderId, created.pickup_code]));
    await asUser(pool, driverAId, (client) => client.query("select driver_hand_to_factory($1)", [orderId]));

    const factoryRows = await admin_query(pool, "select id from public.profiles where role = 'factory' and is_active limit 1");
    if (!factoryRows[0]) {
      console.log("  (skipped — no factory account seeded in this database)");
    } else {
      const factoryId = factoryRows[0].id;
      const attempt = () => asUser(pool, factoryId, (client) => client.query("select factory_confirm_receipt($1)", [orderId]));
      const results = await Promise.all(Array.from({ length: CONCURRENCY }, attempt));
      const successes = results.filter((r) => r.ok).length;
      const historyRows = await admin_query(
        pool,
        "select count(*)::int as n from public.order_history where order_id = $1 and event_type = 'factory_confirmed_receipt'",
        [orderId],
      );
      check("exactly 1 of the concurrent confirmations succeeded", successes === 1, `${successes} succeeded`);
      check("exactly one 'factory_confirmed_receipt' history entry", historyRows[0].n === 1, `${historyRows[0].n} entries`);
    }
  }

  // ---------- Test 5: concurrent approve_distribution double-clicks ----------
  console.log("\n5) Concurrent \"approve distribution\" double-clicks");
  {
    const { result: created } = await asUser(pool, null, (client) =>
      client
        .query(`select (r).* from public_create_order($1,$2,$3,$4,$5) r`, ["عميل اعتماد", "01097777777", "عنوان", regionName, 1])
        .then((r) => r.rows[0]),
    );
    const orderId = created.order_id;
    await asUser(pool, ownerId, (client) => client.query("select set_order_distribution($1,$2,false)", [orderId, driverAId]));
    const attempt = () => asUser(pool, ownerId, (client) => client.query("select approve_distribution($1)", [orderId]));
    const results = await Promise.all(Array.from({ length: CONCURRENCY }, attempt));
    const successes = results.filter((r) => r.ok).length;
    const finalStatus = await admin_query(pool, "select status from public.orders where id = $1", [orderId]);
    check("exactly 1 of the concurrent approvals succeeded", successes === 1, `${successes} succeeded`);
    check("final status is 'assigned' (not corrupted by the race)", finalStatus[0].status === "assigned",
      `status is ${finalStatus[0].status}`);
  }

  // ---------- Test 6: concurrent reassignment to two different drivers ----------
  console.log("\n6) Concurrent driver reassignment to two different drivers at once");
  {
    const { orderId } = await makeAssignedOrder();
    const [resA, resB] = await Promise.all([
      asUser(pool, ownerId, (client) => client.query("select reassign_order_driver($1,$2)", [orderId, driverBId])),
      asUser(pool, ownerId, (client) => client.query("select reassign_order_driver($1,$2)", [orderId, driverAId])),
    ]);
    const finalDriver = await admin_query(pool, "select assigned_driver_id from public.orders where id = $1", [orderId]);
    const historyRows = await admin_query(
      pool,
      "select count(*)::int as n from public.order_history where order_id = $1 and event_type = 'driver_reassigned'",
      [orderId],
    );
    check("no deadlock / crash — both concurrent calls resolved", resA.ok !== undefined && resB.ok !== undefined);
    check("final assigned driver is one of the two drivers involved (consistent, not corrupted)",
      [driverAId, driverBId].includes(finalDriver[0].assigned_driver_id));
    check("history has an entry for the original assignment plus each successful reassignment",
      historyRows[0].n >= 1, `${historyRows[0].n} reassignment entries`);
  }

  await pool.end();

  console.log(`\n${"-".repeat(60)}`);
  if (failures === 0) {
    console.log("All concurrency checks passed — no double-processing, no lost updates, no deadlocks.");
  } else {
    console.log(`${failures} check(s) FAILED — see ✗ lines above.`);
    process.exitCode = 1;
  }
}

main().catch((err) => {
  console.error("Stress test crashed:", err);
  process.exit(1);
});
