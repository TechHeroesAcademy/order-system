// @vitest-environment node

import { describe, it, expect, vi, beforeAll } from "vitest";

const DB = process.env.DATABASE_URL;
const ADMIN = process.env.ADMIN_DATABASE_URL;
const suite = DB ? describe : describe.skip;

let ownerId: string;

vi.mock("@/lib/db/client", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/db/client")>();
  return {
    ...actual,
    currentProfileId: async () => ownerId,
    createClient: async () => {
      const { DbClient } = await import("@/lib/db/query-builder");
      return new DbClient(ownerId);
    },
  };
});

suite("readBatch", () => {
  beforeAll(async () => {
    const pg = (await import("pg")).default;
    const client = new pg.Client({ connectionString: ADMIN ?? DB });
    await client.connect();
    const r = await client.query(
      "select id from public.profiles where role = 'owner' and is_active limit 1",
    );
    await client.end();
    ownerId = r.rows[0]?.id;
    expect(ownerId, "an owner must exist in the target database").toBeTruthy();
  });

  it("refuses a statement carrying a bound value", async () => {
    const { readBatch } = await import("../read-batch");
    await expect(readBatch(["select * from public.orders where id = $1"])).rejects.toThrow(
      /parameterless/,
    );
  });

  it("refuses more than one statement in a string", async () => {
    const { readBatch } = await import("../read-batch");
    await expect(
      readBatch(["select 1; drop table public.orders"]),
    ).rejects.toThrow(/single statements/);
  });

  it("returns one result array per statement, in the order given", async () => {
    const { readBatch } = await import("../read-batch");
    const [a, b, c] = await readBatch([
      "select 1 as n",
      "select 2 as n",
      "select 3 as n",
    ]);
    expect(a[0].n).toBe(1);
    expect(b[0].n).toBe(2);
    expect(c[0].n).toBe(3);
  });

  it("the identity is set, so RLS-scoped reads return the owner's rows", async () => {
    const { readBatch } = await import("../read-batch");
    const [rows] = await readBatch(["select count(*)::int as n from public.orders"]);
    expect(rows[0].n).toBeGreaterThan(0);
  });

  it("the identity does not survive the batch", async () => {
    const { readBatch } = await import("../read-batch");
    await readBatch(["select 1 as n"]);
    const { getPool } = await import("../pool");
    const res = await getPool().query(
      "select current_setting('app.current_profile_id', true) as id",
    );
    expect(res.rows[0].id === null || res.rows[0].id === "").toBe(true);
  });

  it("every batched report equals the same report fetched on its own", async () => {
    const orders = await import("@/lib/data/orders");
    const batched = await orders.getReportsPageData();

    const [daily, monthly, driverPerf, topRegions, delayedOrders, bySource, byCreator] =
      await Promise.all([
        orders.getDailyReport(),
        orders.getMonthlyReport(),
        orders.getDriverPerformance(),
        orders.getTopRegions(),
        orders.getDelayedOrders(),
        orders.getOrdersBySource(),
        orders.getOrdersByCreator(),
      ]);

    expect(batched.daily).toEqual(daily);
    expect(batched.monthly).toEqual(monthly);
    expect(batched.driverPerf).toEqual(driverPerf);
    expect(batched.topRegions).toEqual(topRegions);
    expect(batched.delayedOrders).toEqual(delayedOrders);
    expect(batched.bySource).toEqual(bySource);
    expect(batched.byCreator).toEqual(byCreator);
  });

  it("the batched reports are not merely all equal to each other", async () => {
    const orders = await import("@/lib/data/orders");
    const b = await orders.getReportsPageData();
    expect(b.daily).toHaveProperty("new_orders");
    expect(b.monthly).toHaveProperty("total_pieces");
    expect(Array.isArray(b.driverPerf)).toBe(true);
    expect(Array.isArray(b.topRegions)).toBe(true);
    expect(Array.isArray(b.bySource)).toBe(true);
    expect(Array.isArray(b.byCreator)).toBe(true);
    if (b.bySource.length) expect(b.bySource[0]).toHaveProperty("source");
    if (b.byCreator.length) expect(b.byCreator[0]).toHaveProperty("creator_name");
  });

  it("counts inside the batch are numbers, not strings", async () => {
    const orders = await import("@/lib/data/orders");
    const b = await orders.getReportsPageData();
    expect(typeof b.daily.new_orders).toBe("number");
  });
});
