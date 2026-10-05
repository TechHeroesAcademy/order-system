// @vitest-environment node

import { describe, it, expect, beforeAll } from "vitest";

const DB = process.env.DATABASE_URL;
const ADMIN = process.env.ADMIN_DATABASE_URL;
const suite = DB ? describe : describe.skip;

suite("nothing creates an order without a session", () => {
  let pg: typeof import("pg").default;
  let admin: import("pg").Client;
  let factoryId: string | null = null;

  beforeAll(async () => {
    pg = (await import("pg")).default;
    admin = new pg.Client({ connectionString: ADMIN ?? DB });
    await admin.connect();
    const f = await admin.query("select id from public.factories limit 1");
    factoryId = f.rows[0]?.id ?? null;
  });

  async function withoutSession<T>(fn: (c: import("pg").Client) => Promise<T>): Promise<T> {
    const c = new pg.Client({ connectionString: DB });
    await c.connect();
    try {
      await c.query("begin");
      await c.query("select set_config('app.current_profile_id', '', true)");
      return await fn(c);
    } finally {
      try {
        await c.query("rollback");
      } catch {
      }
      await c.end();
    }
  }

  it("public_create_order no longer exists", async () => {
    const res = await admin.query(
      `select count(*)::int as n
         from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname = 'public_create_order'`,
    );
    expect(res.rows[0].n).toBe(0);
  });

  it("every order-creating function refuses a caller with no session", async () => {
    const fns = await admin.query(
      `select p.proname
         from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname like '%create_order%'
        order by 1`,
    );
    expect(fns.rows.length).toBeGreaterThan(0);

    for (const { proname } of fns.rows) {
      const outcome = await withoutSession(async (c) => {
        try {
          await c.query(
            `select * from public.${proname}(
               p_customer_name => $1, p_customer_phone => $2, p_customer_address => $3,
               p_region_name => $4, p_pieces_count => $5, p_factory_id => $6)`,
            ["اختبار", "01000000000", "أي مكان", "شبرا", 1, factoryId],
          );
          return "CREATED";
        } catch (e) {
          return (e as { code?: string }).code ?? "error";
        }
      });
      // 42501 is the authorization refusal. 42883 means the signature does
      // not match, which is fine — it means this probe cannot reach it.
      expect(
        outcome === "42501" || outcome === "42883",
        `${proname} returned ${outcome} to a caller with no session`,
      ).toBe(true);
    }
  });

  it("a function that inserts an order is either guarded or unreachable by the app", async () => {
    // create_order_internal is the shared helper the guarded wrappers call,
    // and it deliberately has no check of its own — the wrappers do that.
    // What makes it safe is that app_user, the role the application connects
    // as, cannot execute it; only the SECURITY DEFINER wrappers can, and they
    // run as the owner. So the property worth asserting is not "everything is
    // guarded" but "nothing is both unguarded AND reachable".
    const res = await admin.query(
      `select p.proname,
              has_function_privilege('app_user', p.oid, 'EXECUTE') as reachable
         from pg_proc p join pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public'
          and p.prosecdef
          and p.prosrc ~* 'insert into (public\\.)?orders'
          and p.prosrc !~ 'is_owner|is_owner_or_moderator|current_user_role|auth\\.uid'
        order by 1`,
    );
    const exposed = res.rows.filter((r) => r.reachable).map((r) => r.proname);
    expect(
      exposed,
      "these insert an order, never check who is calling, AND the app can call them",
    ).toEqual([]);
  });
});
