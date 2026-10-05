// @vitest-environment node

import { describe, it, expect, beforeAll } from "vitest";
import pg from "pg";

const DB = process.env.DATABASE_URL;
const suite = DB ? describe : describe.skip;

const MUST_BE_SINGLE_OBJECT = [
  "public_create_order",
  "moderator_create_order",
  "driver_create_field_order",
  "send_order_message",
  "create_order_internal",
];

const MUST_STAY_ARRAY_DESPITE_ONE_ROW = [
  "dashboard_stats",
  "customer_order_history",
  "order_customer_context",
  "track_order",
];

suite("rpc result shape", () => {
  let pool: pg.Pool;

  beforeAll(() => {
    pool = new pg.Pool({ connectionString: DB, max: 2 });
  });

  async function isSetReturning(fn: string): Promise<boolean> {
    const res = await pool.query(
      `select coalesce(bool_or(p.proretset), true) as retset
         from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = $1`,
      [fn],
    );
    return res.rows[0]?.retset !== false;
  }

  it.each(MUST_BE_SINGLE_OBJECT)(
    "%s returns a composite, so the shim must unwrap it to one object",
    async (fn) => {
      expect(await isSetReturning(fn)).toBe(false);
    },
  );

  it.each(MUST_STAY_ARRAY_DESPITE_ONE_ROW)(
    "%s is set-returning, so it must stay an array even at one row",
    async (fn) => {
      expect(await isSetReturning(fn)).toBe(true);
    },
  );

  it("an unknown function resolves to the pre-fix behaviour, not a crash", async () => {
    expect(await isSetReturning("no_such_function_anywhere")).toBe(true);
  });

  it("every composite-returning function in public is accounted for here", async () => {
    const res = await pool.query(
      `select p.proname
         from pg_proc p
         join pg_namespace n on n.oid = p.pronamespace
         join pg_type   t on t.oid = p.prorettype
        where n.nspname = 'public'
          and p.proretset = false
          and t.typtype = 'c'
          and p.prokind = 'f'
        order by 1`,
    );
    const found = res.rows.map((r) => r.proname as string);
    expect(found.sort()).toEqual([...MUST_BE_SINGLE_OBJECT].sort());
  });

  it("bigint counts arrive as JavaScript numbers, not strings", async () => {
    await import("../number-types");

    const res = await pool.query("select count(*) as n from public.orders");
    expect(typeof res.rows[0].n).toBe("number");

    const avg = await pool.query("select 1.5::numeric as a");
    expect(typeof avg.rows[0].a).toBe("number");
    expect(avg.rows[0].a).toBe(1.5);

    const stats = await pool.query(
      `select count(*) filter (where status = 'assigned')    as a,
              count(*) filter (where status = 'collected')   as b,
              count(*) filter (where status = 'with_driver') as c
         from public.orders`,
    );
    const { a, b, c } = stats.rows[0];
    expect(typeof (a + b + c)).toBe("number");
    expect(String(a + b + c)).not.toMatch(/^0{2,}$/);
  });
});
