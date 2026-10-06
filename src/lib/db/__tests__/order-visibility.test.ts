// @vitest-environment node
/**
 * Two rules the business depends on, asserted against a real database as real
 * non-superuser sessions:
 *
 *   1. A new order is invisible to every driver until a manager approves the
 *      distribution, and then visible only to the one driver it was given to.
 *   2. A customer refusing delivery is not the end. The driver can reopen the
 *      order and deliver it another day, with the same code.
 */

import { describe, it, expect, beforeAll } from "vitest";

const DB = process.env.DATABASE_URL;
const ADMIN = process.env.ADMIN_DATABASE_URL;
const suite = DB ? describe : describe.skip;

suite("order visibility and delivery retry", () => {
  let pg: typeof import("pg").default;
  let admin: import("pg").Client;
  let ownerId: string;
  let driverA: string;
  let driverB: string;
  let factoryId: string;

  const uniq = () => String(Date.now()).slice(-6) + Math.floor(Math.random() * 900 + 100);

  async function as<T>(id: string | null, fn: (c: import("pg").Client) => Promise<T>): Promise<T> {
    const c = new pg.Client({ connectionString: DB });
    await c.connect();
    try {
      await c.query("begin");
      await c.query("select set_config('app.current_profile_id', $1, true)", [id ?? ""]);
      const out = await fn(c);
      await c.query("commit");
      return out;
    } catch (e) {
      try {
        await c.query("rollback");
      } catch {
      }
      throw e;
    } finally {
      await c.end();
    }
  }

  beforeAll(async () => {
    pg = (await import("pg")).default;
    admin = new pg.Client({ connectionString: ADMIN ?? DB });
    await admin.connect();

    ownerId = (
      await admin.query("select id from public.profiles where role = 'owner' and is_active limit 1")
    ).rows[0]?.id;
    expect(ownerId).toBeTruthy();

    const mk = async (name: string, region: string) =>
      (
        await as(ownerId, (c) =>
          c.query("select * from public.create_staff_account($1,$2,'driver',$3)", [
            name,
            "015" + uniq(),
            [region],
          ]),
        )
      ).rows[0].profile_id as string;

    driverA = await mk("مندوب أ", "شبرا");
    driverB = await mk("مندوب ب", "شبرا");

    factoryId = (
      await as(ownerId, (c) =>
        c.query("select public.create_factory($1,$2,$3,$4,$5,$6) as id", [
          "مصنع " + uniq(),
          "0100" + uniq(),
          "القاهرة",
          30.05,
          31.23,
          null,
        ]),
      )
    ).rows[0].id as string;
  });

  async function newOrder(): Promise<string> {
    const r = await as(ownerId, (c) =>
      c.query(
        `select * from public.moderator_create_order(
           p_customer_name=>$1, p_customer_phone=>$2, p_customer_address=>$3,
           p_region_name=>$4, p_pieces_count=>$5, p_factory_id=>$6,
           p_customer_maps_url=>$7)`,
        ["عميل", "0155" + uniq(), "شبرا الخيمة", "شبرا", 2, factoryId, "https://maps.app.goo.gl/x"],
      ),
    );
    return r.rows[0].order_id as string;
  }

  const seenBy = (driver: string, orderId: string) =>
    as(driver, (c) =>
      c
        .query("select count(*)::int as n from public.orders where id = $1", [orderId])
        .then((r) => r.rows[0].n as number),
    );

  it("a brand new order is invisible to EVERY driver before approval", async () => {
    const id = await newOrder();
    // create_order_internal auto-suggests a covering driver, so this order
    // very likely already has assigned_driver_id set. That suggestion must
    // not be visible to anyone — it is a proposal for the manager, not work.
    const row = await admin.query(
      "select assigned_driver_id, distribution_approved_at, status from public.orders where id = $1",
      [id],
    );
    expect(row.rows[0].distribution_approved_at).toBeNull();

    expect(await seenBy(driverA, id)).toBe(0);
    expect(await seenBy(driverB, id)).toBe(0);
  });

  it("after approval only the assigned driver sees it", async () => {
    const id = await newOrder();
    await as(ownerId, (c) =>
      c.query("select public.set_order_distribution($1, $2)", [id, driverA]),
    );
    expect(await seenBy(driverA, id)).toBe(0);

    await as(ownerId, (c) => c.query("select public.approve_distribution($1)", [id]));

    expect(await seenBy(driverA, id)).toBe(1);
    expect(await seenBy(driverB, id)).toBe(0);
  });

  it("reassigning takes it away from the first driver", async () => {
    const id = await newOrder();
    await as(ownerId, (c) => c.query("select public.set_order_distribution($1,$2)", [id, driverA]));
    await as(ownerId, (c) => c.query("select public.approve_distribution($1)", [id]));
    expect(await seenBy(driverA, id)).toBe(1);

    await as(ownerId, (c) =>
      c.query("select public.reassign_order_driver($1,$2)", [id, driverB]),
    );
    expect(await seenBy(driverA, id)).toBe(0);
    expect(await seenBy(driverB, id)).toBe(1);
  });

  async function driveToWithDriver(id: string, driver: string) {
    await as(ownerId, (c) => c.query("select public.set_order_distribution($1,$2)", [id, driver]));
    await as(ownerId, (c) => c.query("select public.approve_distribution($1)", [id]));
    const pickup = await as(ownerId, (c) =>
      c.query("select public.get_order_pickup_code($1) as code", [id]),
    );
    await as(driver, (c) =>
      c.query("select public.driver_mark_collected($1,$2)", [id, pickup.rows[0].code]),
    );
    await as(driver, (c) => c.query("select public.factory_confirm_receipt($1)", [id]));
    await as(driver, (c) => c.query("select public.factory_mark_ready($1)", [id]));
    await as(driver, (c) => c.query("select public.driver_confirm_factory_pickup($1)", [id]));
    const st = await admin.query("select status from public.orders where id = $1", [id]);
    expect(st.rows[0].status).toBe("with_driver");
  }

  it("a refused order can be delivered on another day, with the same code", async () => {
    const id = await newOrder();
    await driveToWithDriver(id, driverA);

    const code = (
      await as(ownerId, (c) => c.query("select public.get_order_delivery_code($1) as code", [id]))
    ).rows[0].code as string;

    await as(driverA, (c) =>
      c.query("select public.driver_log_refusal($1,$2)", [id, "العميل مش موجود"]),
    );
    let row = await admin.query(
      "select status, refused_at, refusal_count from public.orders where id = $1",
      [id],
    );
    expect(row.rows[0].status).toBe("refused");
    expect(row.rows[0].refusal_count).toBe(1);

    // Delivering while refused must not be possible.
    await expect(
      as(driverA, (c) =>
        c.query("select public.driver_deliver_to_customer($1,$2)", [id, code]),
      ),
    ).rejects.toThrow();

    // Reopen it — this is the new path.
    await as(driverA, (c) => c.query("select public.driver_retry_delivery($1)", [id]));
    row = await admin.query(
      "select status, refused_at, refusal_count from public.orders where id = $1",
      [id],
    );
    expect(row.rows[0].status).toBe("with_driver");
    expect(row.rows[0].refused_at).toBeNull();
    expect(row.rows[0].refusal_count, "the refusal still happened").toBe(1);

    // The SAME code still works.
    const delivered = await as(driverA, (c) =>
      c.query("select public.driver_deliver_to_customer($1,$2) as ok", [id, code]),
    );
    expect(delivered.rows[0].ok).toBe(true);
    row = await admin.query("select status from public.orders where id = $1", [id]);
    expect(row.rows[0].status).toBe("delivered");
  });

  it("a second refusal counts, and can be reopened again", async () => {
    const id = await newOrder();
    await driveToWithDriver(id, driverA);
    for (let i = 1; i <= 2; i++) {
      await as(driverA, (c) =>
        c.query("select public.driver_log_refusal($1,$2)", [id, `محاولة ${i}`]),
      );
      await as(driverA, (c) => c.query("select public.driver_retry_delivery($1)", [id]));
    }
    const row = await admin.query(
      "select status, refusal_count from public.orders where id = $1",
      [id],
    );
    expect(row.rows[0].status).toBe("with_driver");
    expect(row.rows[0].refusal_count).toBe(2);
  });

  it("another driver cannot reopen someone else's refused order", async () => {
    const id = await newOrder();
    await driveToWithDriver(id, driverA);
    await as(driverA, (c) => c.query("select public.driver_log_refusal($1,$2)", [id, "سبب"]));

    await expect(
      as(driverB, (c) => c.query("select public.driver_retry_delivery($1)", [id])),
    ).rejects.toMatchObject({ code: "42501" });

    await expect(
      as(null, (c) => c.query("select public.driver_retry_delivery($1)", [id])),
    ).rejects.toMatchObject({ code: "42501" });
  });

  it("an order that was never refused cannot be reopened", async () => {
    const id = await newOrder();
    await driveToWithDriver(id, driverA);
    await expect(
      as(driverA, (c) => c.query("select public.driver_retry_delivery($1)", [id])),
    ).rejects.toThrow(/رفض/);
  });
});
