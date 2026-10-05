import "server-only";
import type { QueryResultRow } from "pg";
import { withUserContext, type Querier } from "./with-user-context";

const setReturningCache = new Map<string, boolean>();

async function isSetReturning(q: Querier, fn: string): Promise<boolean> {
  const cached = setReturningCache.get(fn);
  if (cached !== undefined) return cached;

  const res = await q.query(
    `select coalesce(bool_or(p.proretset), true) as retset
       from pg_proc p
       join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = $1`,
    [fn],
  );
  const retset = res.rows[0]?.retset !== false;
  setReturningCache.set(fn, retset);
  return retset;
}

const IDENT = /^[a-z_][a-z0-9_]*$/i;

function ident(name: string): string {
  const trimmed = name.trim();
  if (!IDENT.test(trimmed)) {
    throw new Error(`Unsafe SQL identifier: ${JSON.stringify(name)}`);
  }
  return `"${trimmed}"`;
}

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

  not(column: string, operator: "in", values: unknown[] | string): this {
    if (operator !== "in") throw new Error(`.not() supports only "in" here`);
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

  range(from: number, to: number): this {
    this.offsetValue = from;
    this.limitValue = to - from + 1;
    return this;
  }

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
            clauses.push("false");
            break;
          }
          values.push(f.values);
          clauses.push(`t.${ident(f.column)} = any($${values.length})`);
          break;
        }
        case "notIn": {
          if (f.values.length === 0) break;
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

export class DbClient {
  constructor(private readonly profileId: string | null) {}

  from<T extends QueryResultRow = QueryResultRow>(table: string): QueryBuilder<T> {
    return new QueryBuilder<T>(this.profileId, table);
  }

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

        const fields = res.fields.map((f) => f.name);
        if (fields.length === 1 && fields[0] === fn) {
          const rows = res.rows.map((r) => (r as Record<string, unknown>)[fn]);
          return {
            data: (rows.length <= 1 ? (rows[0] ?? null) : rows) as T,
            error: null,
            count: null,
          };
        }

        if (!(await isSetReturning(q, fn))) {
          return {
            data: (res.rows[0] ?? null) as unknown as T,
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

class RpcCall<T> implements PromiseLike<Result<T>> {
  constructor(private readonly exec: () => Promise<Result<T>>) {}

  then<R1 = Result<T>, R2 = never>(
    onfulfilled?: ((value: Result<T>) => R1 | PromiseLike<R1>) | null,
    onrejected?: ((reason: unknown) => R2 | PromiseLike<R2>) | null,
  ): PromiseLike<R1 | R2> {
    return this.exec().then(onfulfilled, onrejected);
  }

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
