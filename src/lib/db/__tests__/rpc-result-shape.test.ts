// @vitest-environment node
/**
 * The shape .rpc() hands back, driven through the REAL query builder against
 * a REAL database.
 *
 * WHY THIS FILE EXISTS
 *
 * Replacing supabase-js meant replacing PostgREST's result conventions, and
 * one of them was invisible: a function returning SETOF/TABLE became a JSON
 * array, while a function returning a plain composite became a single
 * object. `select * from f()` cannot tell them apart, because Postgres
 * expands a composite into columns — so a one-row TABLE function and a
 * composite-returning function produce byte-identical results.
 *
 * The shim guessed, and guessed array. Every newly created order therefore
 * showed a blank order number and blank pickup and delivery codes: the
 * callers read `data.order_number` off what was actually `[{...}]`. Nothing
 * threw, nothing logged, and the `as NewOrderResult` cast at each call site
 * meant typecheck was silent. The only way to catch that class of mistake is
 * to assert the shape against a live catalog.
 *
 * Skipped unless DATABASE_URL is set, so `npm test` stays hermetic:
 *
 *   DATABASE_URL=postgres://app_user:...@127.0.0.1:5432/neondb npx vitest run rpc-result-shape
 */

import { describe, it, expect, beforeAll } from "vitest";
import pg from "pg";

const DB = process.env.DATABASE_URL;
const suite = DB ? describe : describe.skip;

/** Functions whose callers read fields straight off `data`. */
const MUST_BE_SINGLE_OBJECT = [
  "public_create_order",
  "moderator_create_order",
  "driver_create_field_order",
  "send_order_message",
  // Not reachable through .rpc() — it is the shared internal the three
  // create functions wrap — but it returns the same composite, so it belongs
  // in the inventory below rather than looking like an unaccounted-for one.
  "create_order_internal",
];

/**
 * Set-returning functions that always yield exactly one row. These are the
 * reason row count cannot be used to decide the shape: they look identical
 * to the four above and must stay arrays, because their callers index them
 * or call .single().
 */
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

  /** The exact predicate src/lib/db/query-builder.ts asks the catalog. */
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
    // A new RPC that returns a composite is a new instance of the same bug.
    // Rather than hoping someone remembers, fail the moment one appears that
    // this file does not name.
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
    // The owner dashboard adds three of these together. As strings, 0+0+0
    // renders "000". Import the real module for its side effect rather than
    // restating the parsers here — if it ever stops registering them, this
    // test goes red. (pool.ts imports the same module but is "server-only",
    // which is why the registration lives on its own.)
    await import("../number-types");

    const res = await pool.query("select count(*) as n from public.orders");
    expect(typeof res.rows[0].n).toBe("number");

    const avg = await pool.query("select 1.5::numeric as a");
    expect(typeof avg.rows[0].a).toBe("number");
    expect(avg.rows[0].a).toBe(1.5);

    // The actual symptom, reproduced: three counts added.
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
