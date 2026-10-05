import "server-only";
import type { PoolClient, QueryResult, QueryResultRow } from "pg";
import { getPool } from "./pool";

export interface Querier {
  query<T extends QueryResultRow = QueryResultRow>(
    text: string,
    values?: unknown[],
  ): Promise<QueryResult<T>>;
}

export async function withUserContext<T>(
  profileId: string | null,
  fn: (q: Querier) => Promise<T>,
): Promise<T> {
  const client: PoolClient = await getPool().connect();
  try {
    await client.query("begin");

    await client.query("select set_config('app.current_profile_id', $1, true)", [
      profileId ?? "",
    ]);

    const result = await fn({
      query: (text, values) => client.query(text, values as unknown[]),
    });

    await client.query("commit");
    return result;
  } catch (error) {
    try {
      await client.query("rollback");
    } catch {
    }
    throw error;
  } finally {
    client.release();
  }
}

export function withoutUserContext<T>(fn: (q: Querier) => Promise<T>): Promise<T> {
  return withUserContext(null, fn);
}
