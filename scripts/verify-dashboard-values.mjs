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

async function asUser(profileId, fn) {
  const client = await pool.connect();
  try {
    await client.query("begin");
    await client.query("select set_config('app.current_profile_id', $1, true)", [profileId ?? ""]);
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

const uniq = () => String(Date.now()).slice(-7);

async function main() {
  const who = await pool.query(
    "select current_user as u, rolsuper, rolbypassrls from pg_roles where rolname = current_user",
  );
  const me = who.rows[0];
  if (me.rolsuper || me.rolbypassrls) {
    console.error(
      `\nRefusing to run as ${me.u}: it bypasses RLS, which makes every check pass falsely.`,
    );
    process.exit(2);
  }
  console.log(`\nconnected as ${me.u} (superuser: false, bypassrls: false)\n`);

  console.log("=== setting up one real order ===");

  let ownerId = (
    await asUser(null, (c) => c.query("select public.owner_exists() as e"))
  ).rows[0].e
    ? null
    : undefined;

  const boot = await asUser(null, (c) =>
    c.query("select * from public.bootstrap_owner($1, $2, $3)", [
      "مالك الاختبار",
      "011" + uniq() + "1",
      "secret123",
    ]),
  );
  if (boot.rows[0]?.status === "ok") {
    ownerId = boot.rows[0].profile_id;
  } else {
    const adminUrl = process.env.ADMIN_DATABASE_URL;
    if (!adminUrl) {
      console.error(
        "\nThis database already has an owner. Set ADMIN_DATABASE_URL (the database\n" +
          "owner's connection string) so the existing owner can be looked up, or point\n" +
          "DATABASE_URL at a freshly migrated database.",
      );
      process.exit(2);
    }
    const admin = new pg.Client({ connectionString: adminUrl });
    await admin.connect();
    const r = await admin.query(
      "select id from public.profiles where role = 'owner' and is_active limit 1",
    );
    await admin.end();
    ownerId = r.rows[0]?.id;
  }
  check("an owner identity is available", Boolean(ownerId), boot.rows[0]?.status);
  if (!ownerId) {
    console.error("cannot continue without an owner");
    process.exit(1);
  }

  const driver = await asUser(ownerId, (c) =>
    c.query("select * from public.create_staff_account($1, $2, $3, $4)", [
      "سائق الاختبار",
      "012" + uniq() + "2",
      "driver",
      ["شبرا"],
    ]),
  );
  const driverId = driver.rows[0]?.profile_id;
  check("a driver exists with coverage", Boolean(driverId), driver.rows[0]?.status);

  const factory = await asUser(ownerId, (c) =>
    c.query("select public.create_factory($1, $2, $3, $4, $5, $6) as factory_id", [
      "مصنع الاختبار " + uniq(),
      "0100000" + uniq().slice(0, 4),
      "القاهرة",
      30.05,
      31.23,
      null,
    ]),
  );
  const factoryId = factory.rows[0]?.factory_id ?? factory.rows[0]?.id;
  check("a factory exists to route to", Boolean(factoryId));

  const created = await asUser(ownerId, (c) =>
    c.query(
      `select * from public.moderator_create_order(
         p_customer_name    => $1,
         p_customer_phone   => $2,
         p_customer_address => $3,
         p_region_name      => $4,
         p_pieces_count     => $5,
         p_factory_id       => $6,
         p_customer_maps_url => $7)`,
      [
        "عميل الاختبار",
        "0155" + uniq(),
        "شبرا الخيمة",
        "شبرا",
        3,
        factoryId,
        "https://maps.app.goo.gl/testlink",
      ],
    ),
  );
  const row = created.rows[0] ?? {};
  const orderId = row.order_id ?? row.id;
  check("an order was created", Boolean(orderId), JSON.stringify(row).slice(0, 200));
  if (!orderId) {
    console.error("cannot continue without an order");
    process.exit(1);
  }

  console.log("\n=== symptom: the order number does not appear ===");

  check(
    "moderator_create_order RETURNS an order_number",
    typeof row.order_number === "string" && row.order_number.length > 0,
    `got ${JSON.stringify(row.order_number)}`,
  );

  const stored = await asUser(ownerId, (c) =>
    c.query("select order_number, status from public.orders where id = $1", [orderId]),
  );
  const storedNumber = stored.rows[0]?.order_number;
  check(
    "the order row has an order_number STORED (the trigger fired)",
    typeof storedNumber === "string" && /^ORD-\d{5}$/.test(storedNumber),
    `got ${JSON.stringify(storedNumber)}`,
  );

  const driverCols =
    "id, order_number, status, customer_name, customer_address, region_id, created_at, delivered_at, refused_at";
  const projected = await asUser(ownerId, (c) =>
    c.query(`select ${driverCols} from public.orders where id = $1`, [orderId]),
  );
  check(
    "order_number survives the driver list's column projection",
    Boolean(projected.rows[0]?.order_number),
    `got ${JSON.stringify(projected.rows[0]?.order_number)}`,
  );

  console.log("\n=== symptom: the pickup and delivery codes do not appear ===");

  const dcOne = await asUser(ownerId, (c) =>
    c.query("select public.get_order_delivery_code($1) as code", [orderId]),
  );
  check(
    "get_order_delivery_code() returns a 4-digit code to the owner",
    /^\d{4}$/.test(String(dcOne.rows[0]?.code ?? "")),
    `got ${JSON.stringify(dcOne.rows[0]?.code)}`,
  );

  const pcOne = await asUser(ownerId, (c) =>
    c.query("select public.get_order_pickup_code($1) as code", [orderId]),
  );
  check(
    "get_order_pickup_code() returns a 4-digit code to the owner",
    /^\d{4}$/.test(String(pcOne.rows[0]?.code ?? "")),
    `got ${JSON.stringify(pcOne.rows[0]?.code)}`,
  );

  const dcMany = await asUser(ownerId, (c) =>
    c.query("select * from public.get_order_delivery_codes($1::uuid[])", [[orderId]]),
  );
  check(
    "get_order_delivery_codes() (the list page's batch call) returns a row",
    dcMany.rows.length === 1 && /^\d{4}$/.test(String(dcMany.rows[0]?.code ?? "")),
    `${dcMany.rows.length} row(s): ${JSON.stringify(dcMany.rows[0])}`,
  );
  check(
    "the batch call's code MATCHES the single call's code",
    dcMany.rows[0]?.code === dcOne.rows[0]?.code,
    `${dcMany.rows[0]?.code} vs ${dcOne.rows[0]?.code}`,
  );

  const rawCodes = await asUser(ownerId, (c) =>
    c
      .query("select count(*)::int as n from public.order_delivery_codes")
      .then((r) => (r.rows[0].n === 0 ? "empty" : `VISIBLE ${r.rows[0].n}`))
      .catch((e) => e.code),
  );
  check(
    "the plaintext code table is still unreachable (the reason the RPC exists)",
    rawCodes === "empty" || rawCodes === "42501",
    `got ${rawCodes}`,
  );

  const codeNoSession = await asUser(null, (c) =>
    c
      .query("select public.get_order_delivery_code($1) as code", [orderId])
      .then(() => "returned")
      .catch((e) => e.code),
  );
  check(
    "and an unauthenticated caller is refused the code",
    codeNoSession === "42501",
    `got ${codeNoSession}`,
  );

  console.log("\n=== symptom: the order counts on the dashboard do not appear ===");

  const stats = await asUser(ownerId, (c) => c.query("select * from public.dashboard_stats()"));
  const s = stats.rows[0] ?? {};
  check("dashboard_stats() returns a row to the owner", stats.rows.length === 1);
  console.log(`        -> ${JSON.stringify(s)}`);

  const numericKeys = Object.keys(s).filter((k) => typeof s[k] === "number" || /^\d+$/.test(String(s[k])));
  check(
    "dashboard_stats() has numeric count columns",
    numericKeys.length > 0,
    `keys: ${Object.keys(s).join(", ")}`,
  );
  const anyNonZero = numericKeys.some((k) => Number(s[k]) > 0);
  check(
    "at least one count is NON-ZERO now that an order exists",
    anyNonZero,
    `all zero: ${JSON.stringify(s)}`,
  );

  const listRows = await asUser(ownerId, (c) =>
    c.query("select id from public.orders order by created_at desc limit 20 offset 0"),
  );
  const listCount = await asUser(ownerId, (c) =>
    c.query("select count(*)::text as n from public.orders"),
  );
  check(
    "the list's rows and its exact count agree",
    Number(listCount.rows[0].n) >= listRows.rows.length && Number(listCount.rows[0].n) > 0,
    `count=${listCount.rows[0].n}, rows=${listRows.rows.length}`,
  );

  const srcReport = await asUser(ownerId, (c) =>
    c.query("select * from public.orders_by_source_report()"),
  );
  check(
    "orders_by_source_report() returns rows to the owner",
    srcReport.rows.length > 0,
    `${srcReport.rows.length} rows`,
  );

  console.log("\n=== the same three, as a moderator ===");

  const mod = await asUser(ownerId, (c) =>
    c.query("select * from public.create_staff_account($1, $2, $3, $4)", [
      "مشرف الاختبار",
      "013" + uniq() + "3",
      "moderator",
      [],
    ]),
  );
  const modId = mod.rows[0]?.profile_id;
  check("a moderator exists", Boolean(modId), mod.rows[0]?.status);

  if (modId) {
    const modNumber = await asUser(modId, (c) =>
      c.query("select order_number from public.orders where id = $1", [orderId]),
    );
    check(
      "a moderator sees the order_number",
      Boolean(modNumber.rows[0]?.order_number),
      `${modNumber.rows.length} row(s)`,
    );

    const modCode = await asUser(modId, (c) =>
      c
        .query("select public.get_order_delivery_code($1) as code", [orderId])
        .then((r) => r.rows[0]?.code)
        .catch((e) => `ERR ${e.code}`),
    );
    check("a moderator can read the delivery code", /^\d{4}$/.test(String(modCode)), `got ${modCode}`);

    const modStats = await asUser(modId, (c) => c.query("select * from public.dashboard_stats()"));
    check("a moderator gets dashboard_stats()", modStats.rows.length === 1);
  }

  console.log("\n=== and the driver, who must not read the codes ===");

  if (driverId) {
    const driverCode = await asUser(driverId, (c) =>
      c
        .query("select public.get_order_delivery_code($1) as code", [orderId])
        .then((r) => `returned ${r.rows[0]?.code}`)
        .catch((e) => e.code),
    );
    check(
      "the driver is refused the delivery code",
      driverCode === "42501",
      `got ${driverCode}`,
    );
  }

  console.log(`\n=== ${passed} passed, ${failures.length} failed ===`);
  if (failures.length) {
    console.log("\nfailed:");
    for (const f of failures) console.log(`  - ${f}`);
    process.exit(1);
  }
}

main()
  .catch((e) => {
    console.error("\nunexpected error:", e.message);
    process.exit(1);
  })
  .finally(() => pool.end());
