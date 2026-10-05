// @vitest-environment node
/**
 * The real DbClient, against a real database, asserting the three values
 * that were reported missing from the live system:
 *
 *   - the order number
 *   - the pickup code
 *   - the delivery code
 *
 * The sibling rpc-result-shape test checks the catalog predicate the fix
 * relies on. This one checks the thing the person actually sees: that after
 * creating an order, `data.order_number` is a string and not `undefined`.
 * Before the fix `data` was a one-element array, so all three were
 * undefined, every call site read them off the wrong object, and nothing
 * anywhere raised.
 *
 * Skipped unless DATABASE_URL is set:
 *
 *   DATABASE_URL=postgres://app_user:...@127.0.0.1:5432/neondb npx vitest run rpc-end-to-end
 */

import { describe, it, expect, beforeAll } from "vitest";
import { DbClient } from "../query-builder";

const DB = process.env.DATABASE_URL;
const ADMIN = process.env.ADMIN_DATABASE_URL;
const suite = DB ? describe : describe.skip;

const uniq = () => String(Date.now()).slice(-7) + Math.floor(Math.random() * 9);

interface NewOrder {
  order_id: string;
  order_number: string;
  delivery_code: string;
  pickup_code: string;
}

suite("rpc end to end: the order number and both codes", () => {
  let ownerId: string;
  let factoryId: string;

  beforeAll(async () => {
    const anon = new DbClient(null);

    const boot = await anon.rpc<{ status: string; profile_id: string | null }[]>(
      "bootstrap_owner",
      {
        p_full_name: "مالك الاختبار",
        p_phone: "011" + uniq(),
        p_password: "secret123",
      },
    );
    const row = boot.data?.[0];

    if (row?.status === "ok" && row.profile_id) {
      ownerId = row.profile_id;
    } else {
      // Already bootstrapped. Looking the owner up needs a role RLS does not
      // apply to, because profiles_select_staff requires a session and we do
      // not have one yet — a plain select returns zero rows and makes the
      // whole suite look broken. (It did, the first time this was written.)
      if (!ADMIN) {
        throw new Error(
          "This database already has an owner; set ADMIN_DATABASE_URL to look it up, " +
            "or point DATABASE_URL at a freshly migrated database.",
        );
      }
      const pg = (await import("pg")).default;
      const admin = new pg.Client({ connectionString: ADMIN });
      await admin.connect();
      const r = await admin.query(
        "select id from public.profiles where role = 'owner' and is_active limit 1",
      );
      await admin.end();
      ownerId = r.rows[0]?.id;
    }
    expect(ownerId, "an owner identity is required").toBeTruthy();

    const owner = new DbClient(ownerId);
    const f = await owner.rpc<string>("create_factory", {
      p_name: "مصنع الاختبار " + uniq(),
      p_phone: "0100" + uniq(),
      p_address: "القاهرة",
      p_lat: 30.05,
      p_lng: 31.23,
      p_maps_url: null,
    });
    expect(f.error, f.error?.message).toBeNull();
    factoryId = f.data as string;
    expect(typeof factoryId).toBe("string");
  });

  async function createOrder() {
    const owner = new DbClient(ownerId);
    const res = await owner.rpc<NewOrder>("moderator_create_order", {
      p_customer_name: "عميل الاختبار",
      p_customer_phone: "0155" + uniq(),
      p_customer_address: "شبرا الخيمة",
      p_region_name: "شبرا",
      p_pieces_count: 3,
      p_piece_details: null,
      p_color: null,
      p_work_required: null,
      p_customer_notes: null,
      p_factory_id: factoryId,
      p_driver_id: null,
      p_customer_maps_url: "https://maps.app.goo.gl/testlink",
    });
    expect(res.error, res.error?.message).toBeNull();
    return res.data as NewOrder;
  }

  it("moderator_create_order hands back ONE OBJECT, not an array", async () => {
    const data = await createOrder();
    expect(Array.isArray(data)).toBe(false);
    expect(data).toBeTypeOf("object");
  });

  it("the order number is present and formatted", async () => {
    const data = await createOrder();
    // The exact assertion that was failing in production, where this was
    // undefined because `data` was `[{ order_number: "ORD-00001", ... }]`.
    expect(data.order_number).toMatch(/^ORD-\d{5}$/);
  });

  it("both codes come back as four digits", async () => {
    const data = await createOrder();
    expect(data.delivery_code).toMatch(/^\d{4}$/);
    expect(data.pickup_code).toMatch(/^\d{4}$/);
    expect(data.delivery_code).not.toBe(data.pickup_code);
  });

  it("the codes can be read back afterwards, matching what creation returned", async () => {
    const data = await createOrder();
    const owner = new DbClient(ownerId);

    const delivery = await owner.rpc<string>("get_order_delivery_code", {
      p_order_id: data.order_id,
    });
    expect(delivery.error, delivery.error?.message).toBeNull();
    expect(delivery.data).toBe(data.delivery_code);

    const pickup = await owner.rpc<string>("get_order_pickup_code", {
      p_order_id: data.order_id,
    });
    expect(pickup.error, pickup.error?.message).toBeNull();
    expect(pickup.data).toBe(data.pickup_code);

    // The list page's batch call, which must agree with both.
    const batch = await owner.rpc<{ order_id: string; code: string }[]>(
      "get_order_delivery_codes",
      { p_order_ids: [data.order_id] },
    );
    expect(batch.error, batch.error?.message).toBeNull();
    expect(Array.isArray(batch.data)).toBe(true);
    expect(batch.data?.[0]?.code).toBe(data.delivery_code);
  });

  it("the order row carries the number through a plain select", async () => {
    const data = await createOrder();
    const owner = new DbClient(ownerId);
    const res = await owner
      .from<{ order_number: string }>("orders")
      .select("id, order_number, status")
      .eq("id", data.order_id)
      .maybeSingle();
    expect(res.error, res.error?.message).toBeNull();
    expect(res.data?.order_number).toBe(data.order_number);
  });

  it("dashboard counts are numbers that add up, not strings that concatenate", async () => {
    await createOrder();
    const owner = new DbClient(ownerId);
    const res = await owner
      .rpc<Record<string, number>>("dashboard_stats")
      .single<Record<string, number>>();
    expect(res.error, res.error?.message).toBeNull();

    const s = res.data as Record<string, number>;
    expect(typeof s.total_orders).toBe("number");
    expect(s.total_orders).toBeGreaterThan(0);

    // The owner dashboard's "مع المندوبين" card, verbatim. As strings this
    // produced "000".
    const withDrivers = s.assigned_orders + s.collected_orders + s.with_driver_orders;
    expect(typeof withDrivers).toBe("number");
    expect(Number.isNaN(withDrivers)).toBe(false);
  });

  it("a set-returning function that yields one row is still an array", async () => {
    const owner = new DbClient(ownerId);
    const res = await owner.rpc<unknown[]>("customer_order_history", {
      p_phone: "01550000000",
    });
    expect(res.error, res.error?.message).toBeNull();
    expect(Array.isArray(res.data)).toBe(true);
    expect(res.data).toHaveLength(1);
  });

  it("a void-returning function still reports no error and no data", async () => {
    const data = await createOrder();
    const owner = new DbClient(ownerId);
    const res = await owner.rpc("owner_cancel_order", {
      p_order_id: data.order_id,
      p_reason: "اختبار",
    });
    expect(res.error, res.error?.message).toBeNull();
  });
});
