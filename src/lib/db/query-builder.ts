import "server-only";
import type { QueryResultRow } from "pg";
import { withUserContext, type Querier } from "./with-user-context";

/**
 * A small query builder with the same shape as the one supabase-js gave us.
 *
 * WHY A SHIM RATHER THAN 42 HAND-WRITTEN QUERIES
 *
 * The 42 table queries in this app are spread across 12 files and are, with
 * two exceptions, plain filters. Translating each one by hand means 42
 * chances to drop an `.eq()`, invert a range, or quietly widen what a driver
 * can see — and the ones that would hurt most are the ones that still
 * return rows afterwards. Keeping the call shape and replacing the engine
 * means those files are read and re-read against a diff of imports, not a
 * diff of logic.
 *
 * It is deliberately NOT a general PostgREST implementation. It supports
 * exactly the methods this codebase uses, counted from the source:
 * select/insert/update/delete, eq/in/not/is/gte/lte/lt, order, range, limit,
 * single/maybeSingle, and the { count: "exact" } option. Anything else is a
 * compile error rather than a silent no-op, which is the point — a shim that
 * accepts a filter it does not apply is worse than no shim.
 *
 * Every value goes through a bound parameter. Only identifiers (table and
 * column names) are interpolated, and those are validated against a strict
 * pattern first, so a column name arriving from somewhere unexpected cannot
 * become SQL.
 *
 * Each terminal call runs in its own withUserContext transaction. That
 * matches what it replaces: under PostgREST every .from() was a separate
 * HTTP request and therefore a separate transaction, so nothing about
 * atomicity changes. Where several statements must be atomic, this codebase
 * already puts them in a SECURITY DEFINER function, which is where that
 * belongs.
 */

/** Identifiers are interpolated, so they are checked rather than trusted. */
const IDENT = /^[a-z_][a-z0-9_]*$/i;

function ident(name: string): string {
  const trimmed = name.trim();
  if (!IDENT.test(trimmed)) {
    throw new Error(`Unsafe SQL identifier: ${JSON.stringify(name)}`);
  }
  return `"${trimmed}"`;
}

/**
 * The two embedded selects this app uses, declared rather than parsed.
 *
 * PostgREST turns `*, region:regions(name)` into a nested object by
 * following the foreign key. A general implementation of that is a schema
 * crawler; there are two of these in the whole codebase, so they are listed
 * here instead and anything else throws. A third one added later fails
 * loudly at the call site rather than silently returning no nested object.
 */
const EMBEDS: Record<string, { sql: string; alias: string }> = {
  "*, region:regions(name)": {
    alias: "region",
    sql: `(select jsonb_build_object('name', r.name) from public.regions r where r.id = t.region_id) as "region"`,
  },
  "*, sender:profiles!order_messages_sender_id_fkey(full_name)": {
    alias: "sender",
    sql: `(select jsonb_build_object('full_name', p.full_name) from public.profiles p where p.id = t.sender_id) as "sender"`,
  },
};

type Filter =
  | { kind: "eq" | "gte" | "lte" | "lt" | "gt"; column: string; value: unknown }
  | { kind: "in"; column: string; values: unknown[] }
  | { kind: "notIn"; column: string; values: unknown[] }
  | { kind: "is"; column: string; value: null }
  | { kind: "orIlike"; columns: string[]; term: string };

interface SelectOptions {
  count?: "exact";
  head?: boolean;
}

export interface Result<T> {
  data: T | null;
  error: { message: string; code?: string } | null;
  count: number | null;
}

/** Postgres error shape, narrowed without `any`. */
function toResultError(e: unknown): { message: string; code?: string } {
  if (e && typeof e === "object") {
    const o = e as { message?: unknown; code?: unknown };
    return {
      message: typeof o.message === "string" ? o.message : "database error",
      code: typeof o.code === "string" ? o.code : undefined,
    };
  }
  return { message: "database error" };
}

class QueryBuilder<T extends QueryResultRow> implements PromiseLike<Result<T[]>> {
  private filters: Filter[] = [];
  private columns = "*";
  private options: SelectOptions = {};
  private orderBy: { column: string; ascending: boolean; nullsFirst?: boolean }[] = [];
  private limitValue: number | null = null;
  private offsetValue = 0;
  private mode: "select" | "insert" | "update" | "delete" = "select";
  private payload: Record<string, unknown> | Record<string, unknown>[] | null = null;

  constructor(
    private readonly profileId: string | null,
    private readonly table: string,
  ) {}

  select(columns = "*", options: SelectOptions = {}): this {
    // On an insert/update/delete, .select() means RETURNING rather than a
    // fresh query — same as PostgREST.
    this.columns = columns;
    this.options = options;
    return this;
  }

  insert(payload: Record<string, unknown> | Record<string, unknown>[]): this {
    this.mode = "insert";
    this.payload = payload;
    return this;
  }

  update(payload: Record<string, unknown>): this {
    this.mode = "update";
    this.payload = payload;
    return this;
  }

  delete(): this {
    this.mode = "delete";
    return this;
  }

  eq(column: string, value: unknown): this {
    this.filters.push({ kind: "eq", column, value });
    return this;
  }
  gte(column: string, value: unknown): this {
    this.filters.push({ kind: "gte", column, value });
    return this;
  }
  lte(column: string, value: unknown): this {
    this.filters.push({ kind: "lte", column, value });
    return this;
  }
  lt(column: string, value: unknown): this {
    this.filters.push({ kind: "lt", column, value });
    return this;
  }
  in(column: string, values: unknown[]): this {
    this.filters.push({ kind: "in", column, values });
    return this;
  }
  is(column: string, value: null): this {
    this.filters.push({ kind: "is", column, value });
    return this;
  }

  /**
   * `.not("status", "in", [...])` is the only form of .not() used here, and
   * the signature is narrowed to it on purpose: supabase-js's generic
   * `.not(column, operator, value)` would let a typo in the operator through
   * as a filter that never matches.
   */
  not(column: string, operator: "in", values: unknown[] | string): this {
    if (operator !== "in") throw new Error(`.not() supports only "in" here`);
    // PostgREST took this as the string "(a,b,c)" and two call sites still
    // build it that way. Accepted and parsed rather than changed at the call
    // sites, so the status lists there stay written exactly once — they are
    // derived from TERMINAL_STATUSES, and retyping them as arrays is how the
    // two copies drift.
    const list = Array.isArray(values)
      ? values
      : values
          .replace(/^\(|\)$/g, "")
          .split(",")
          .map((v) => v.trim())
          .filter(Boolean);
    this.filters.push({ kind: "notIn", column, values: list });
    return this;
  }

  /**
   * Replaces the one PostgREST `.or("a.ilike.%x%,b.ilike.%x%")` call site.
   * Explicit columns and one term instead of a string that has to be parsed
   * — the search box is the only thing that uses it.
   */
  orIlike(columns: string[], term: string): this {
    this.filters.push({ kind: "orIlike", columns, term });
    return this;
  }

  order(column: string, opts: { ascending?: boolean; nullsFirst?: boolean } = {}): this {
    this.orderBy.push({
      column,
      ascending: opts.ascending !== false,
      nullsFirst: opts.nullsFirst,
    });
    return this;
  }

  limit(n: number): this {
    this.limitValue = n;
    return this;
  }

  /** Inclusive on both ends, like PostgREST's Range header. */
  range(from: number, to: number): this {
    this.offsetValue = from;
    this.limitValue = to - from + 1;
    return this;
  }

  // ── terminals ─────────────────────────────────────────────────────────

  async maybeSingle<R extends QueryResultRow = T>(): Promise<Result<R | null>> {
    const res = await this.run();
    if (res.error) return { data: null, error: res.error, count: null };
    const rows = (res.data ?? []) as unknown as R[];
    return { data: rows[0] ?? null, error: null, count: res.count };
  }

  async single<R extends QueryResultRow = T>(): Promise<Result<R | null>> {
    const res = await this.run();
    if (res.error) return { data: null, error: res.error, count: null };
    const rows = (res.data ?? []) as unknown as R[];
    if (rows.length !== 1) {
      // PostgREST's PGRST116. Kept as an error rather than returning null so
      // call sites that rely on "exactly one" keep failing loudly.
      return {
        data: null,
        error: { message: "Expected exactly one row", code: "PGRST116" },
        count: res.count,
      };
    }
    return { data: rows[0], error: null, count: res.count };
  }

  then<R1 = Result<T[]>, R2 = never>(
    onfulfilled?: ((value: Result<T[]>) => R1 | PromiseLike<R1>) | null,
    onrejected?: ((reason: unknown) => R2 | PromiseLike<R2>) | null,
  ): PromiseLike<R1 | R2> {
    return this.run().then(onfulfilled, onrejected);
  }

  // ── compilation ───────────────────────────────────────────────────────

  private buildWhere(values: unknown[]): string {
    const clauses: string[] = [];
    for (const f of this.filters) {
      switch (f.kind) {
        case "eq":
        case "gte":
        case "lte":
        case "lt":
        case "gt": {
          const op = { eq: "=", gte: ">=", lte: "<=", lt: "<", gt: ">" }[f.kind];
          values.push(f.value);
          clauses.push(`t.${ident(f.column)} ${op} $${values.length}`);
          break;
        }
        case "in": {
          if (f.values.length === 0) {
            clauses.push("false"); // `in ()` is not valid SQL; nothing matches
            break;
          }
          values.push(f.values);
          clauses.push(`t.${ident(f.column)} = any($${values.length})`);
          break;
        }
        case "notIn": {
          if (f.values.length === 0) break; // excludes nothing
          values.push(f.values);
          clauses.push(`t.${ident(f.column)} <> all($${values.length})`);
          break;
        }
        case "is": {
          clauses.push(`t.${ident(f.column)} is null`);
          break;
        }
        case "orIlike": {
          values.push(`%${f.term}%`);
          const p = `$${values.length}`;
          clauses.push(
            `(${f.columns.map((c) => `t.${ident(c)} ilike ${p}`).join(" or ")})`,
          );
          break;
        }
      }
    }
    return clauses.length ? `where ${clauses.join(" and ")}` : "";
  }

  private buildReturning(): string {
    if (this.columns === "*") return "*";
    const embed = EMBEDS[this.columns];
    if (embed) return `t.*, ${embed.sql}`;
    if (this.columns.includes("(")) {
      throw new Error(
        `Embedded select not registered in EMBEDS: ${JSON.stringify(this.columns)}`,
      );
    }
    return this.columns
      .split(",")
      .map((c) => `t.${ident(c)}`)
      .join(", ");
  }

  private async run(): Promise<Result<T[]>> {
    try {
      return await withUserContext(this.profileId, async (q) => {
        switch (this.mode) {
          case "select":
            return this.runSelect(q);
          case "insert":
            return this.runInsert(q);
          case "update":
            return this.runUpdate(q);
          case "delete":
            return this.runDelete(q);
        }
      });
    } catch (e) {
      return { data: null, error: toResultError(e), count: null };
    }
  }

  private async runSelect(q: Querier): Promise<Result<T[]>> {
    const values: unknown[] = [];
    const where = this.buildWhere(values);
    const table = `public.${ident(this.table)} t`;

    let count: number | null = null;
    if (this.options.count === "exact") {
      // A separate statement, like PostgREST's Content-Range: the count is
      // of the whole filtered set, independent of limit/offset, which is
      // what the "مكتملة (N)" tab and the orders pager both need.
      const r = await q.query<{ n: string }>(
        `select count(*)::text as n from ${table} ${where}`,
        values,
      );
      count = Number(r.rows[0]?.n ?? 0);
      if (this.options.head) return { data: [] as unknown as T[], error: null, count };
    }

    const order = this.orderBy.length
      ? `order by ${this.orderBy
          .map((o) => {
            // Spelled out rather than left to the default. Postgres puts
            // NULLs last on ASC and first on DESC, so the unallocated-orders
            // queue — ordered by needs_allocation_at DESC, where unflagged
            // orders are NULL — would otherwise sort the ones nobody flagged
            // above the ones that need a driver.
            const nulls =
              o.nullsFirst === undefined ? "" : o.nullsFirst ? " nulls first" : " nulls last";
            return `t.${ident(o.column)} ${o.ascending ? "asc" : "desc"}${nulls}`;
          })
          .join(", ")}`
      : "";
    const limit = this.limitValue !== null ? `limit ${Number(this.limitValue)}` : "";
    const offset = this.offsetValue ? `offset ${Number(this.offsetValue)}` : "";

    const res = await q.query<T>(
      `select ${this.buildReturning()} from ${table} ${where} ${order} ${limit} ${offset}`,
      values,
    );
    return { data: res.rows, error: null, count };
  }

  private async runInsert(q: Querier): Promise<Result<T[]>> {
    const rows = Array.isArray(this.payload) ? this.payload : [this.payload!];
    if (rows.length === 0) return { data: [] as unknown as T[], error: null, count: null };

    // One column list for the whole batch, taken from the first row. Every
    // insert in this codebase is a batch of uniform rows; a ragged batch
    // would silently drop columns, so it is rejected.
    const cols = Object.keys(rows[0]);
    for (const r of rows) {
      const k = Object.keys(r);
      if (k.length !== cols.length || k.some((c) => !cols.includes(c))) {
        throw new Error("insert(): every row must have the same columns");
      }
    }

    const values: unknown[] = [];
    const tuples = rows.map((r) => {
      const ps = cols.map((c) => {
        values.push(r[c]);
        return `$${values.length}`;
      });
      return `(${ps.join(", ")})`;
    });

    const res = await q.query<T>(
      `insert into public.${ident(this.table)} as t (${cols.map(ident).join(", ")})
       values ${tuples.join(", ")}
       returning ${this.buildReturning()}`,
      values,
    );
    return { data: res.rows, error: null, count: null };
  }

  private async runUpdate(q: Querier): Promise<Result<T[]>> {
    const payload = this.payload as Record<string, unknown>;
    const values: unknown[] = [];
    const sets = Object.keys(payload).map((c) => {
      values.push(payload[c]);
      return `${ident(c)} = $${values.length}`;
    });
    if (sets.length === 0) throw new Error("update(): nothing to set");

    const where = this.buildWhere(values);
    // An UPDATE with no WHERE would rewrite the table. Every call site has
    // one; this makes a future one that forgets fail instead of succeed.
    if (!where) throw new Error("update(): refusing to run without a filter");

    const res = await q.query<T>(
      `update public.${ident(this.table)} as t set ${sets.join(", ")} ${where}
       returning ${this.buildReturning()}`,
      values,
    );
    return { data: res.rows, error: null, count: null };
  }

  private async runDelete(q: Querier): Promise<Result<T[]>> {
    const values: unknown[] = [];
    const where = this.buildWhere(values);
    if (!where) throw new Error("delete(): refusing to run without a filter");

    const res = await q.query<T>(
      `delete from public.${ident(this.table)} as t ${where}
       returning ${this.buildReturning()}`,
      values,
    );
    return { data: res.rows, error: null, count: null };
  }
}

/**
 * A database handle bound to one identity for the length of a request.
 *
 * `.from()` and `.rpc()` keep the shapes the application already calls, so
 * the 88 call sites did not have to be rewritten by hand. The identity is
 * fixed at construction from the verified session and cannot be changed
 * afterwards — there is no setter.
 */
export class DbClient {
  constructor(private readonly profileId: string | null) {}

  from<T extends QueryResultRow = QueryResultRow>(table: string): QueryBuilder<T> {
    return new QueryBuilder<T>(this.profileId, table);
  }

  /**
   * Calls a Postgres function. Named arguments, matching how the SQL
   * declares them, so adding a parameter with a default never shifts the
   * meaning of an existing call — which positional arguments would.
   *
   * Scalar- and composite-returning functions come back as the value
   * itself; set-returning ones as an array. That mirrors PostgREST, and
   * .single() on the result narrows it the same way it did.
   */
  rpc<T = unknown>(fn: string, args: Record<string, unknown> = {}): RpcCall<T> {
    return new RpcCall<T>(() => this.runRpc<T>(fn, args));
  }

  private async runRpc<T>(
    fn: string,
    args: Record<string, unknown> = {},
  ): Promise<Result<T>> {
    try {
      const names = Object.keys(args);
      const values = names.map((n) => args[n]);
      const argList = names.map((n, i) => `${ident(n)} => $${i + 1}`).join(", ");

      return await withUserContext(this.profileId, async (q) => {
        const res = await q.query(`select * from public.${ident(fn)}(${argList})`, values);

        // A function returning a single scalar or a single unnamed composite
        // arrives as one row with one column named after the function.
        const fields = res.fields.map((f) => f.name);
        if (fields.length === 1 && fields[0] === fn) {
          const rows = res.rows.map((r) => (r as Record<string, unknown>)[fn]);
          return {
            data: (rows.length <= 1 ? (rows[0] ?? null) : rows) as T,
            error: null,
            count: null,
          };
        }
        return { data: res.rows as unknown as T, error: null, count: null };
      });
    } catch (e) {
      return { data: null, error: toResultError(e), count: null };
    }
  }
}

/**
 * The result of .rpc(), awaitable directly or narrowed with .single().
 *
 * supabase-js returned a builder here, and ten call sites chain .single() on
 * a report function that returns one row. Keeping that shape means those
 * call sites were not touched.
 */
class RpcCall<T> implements PromiseLike<Result<T>> {
  constructor(private readonly exec: () => Promise<Result<T>>) {}

  then<R1 = Result<T>, R2 = never>(
    onfulfilled?: ((value: Result<T>) => R1 | PromiseLike<R1>) | null,
    onrejected?: ((reason: unknown) => R2 | PromiseLike<R2>) | null,
  ): PromiseLike<R1 | R2> {
    return this.exec().then(onfulfilled, onrejected);
  }

  /**
   * One row rather than an array, for a set-returning function that yields
   * exactly one — dashboard_stats, daily_report, monthly_report.
   *
   * An empty result is an error, not null: every caller of this treats the
   * value as present and would otherwise read fields off undefined.
   */
  async single<R = T>(): Promise<Result<R>> {
    const res = await this.exec();
    if (res.error) return { data: null, error: res.error, count: null };
    const rows = res.data as unknown;
    if (Array.isArray(rows)) {
      if (rows.length !== 1) {
        return {
          data: null,
          error: { message: `Expected exactly one row, got ${rows.length}`, code: "PGRST116" },
          count: null,
        };
      }
      return { data: rows[0] as R, error: null, count: null };
    }
    return { data: rows as R, error: null, count: null };
  }
}
