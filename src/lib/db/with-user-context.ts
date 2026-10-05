import "server-only";
import type { PoolClient, QueryResult, QueryResultRow } from "pg";
import { getPool } from "./pool";

export interface Querier {
  query<T extends QueryResultRow = QueryResultRow>(
    text: string,
    values?: unknown[],
  ): Promise<QueryResult<T>>;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function openTransaction(client: PoolClient, profileId: string | null): Promise<unknown> {
  if (profileId === null || profileId === "") {
    return client.query("begin; select set_config('app.current_profile_id', '', true)");
  }
  if (!UUID.test(profileId)) {
    throw new Error("profileId is not a uuid");
  }
  return client.query(
    `begin; select set_config('app.current_profile_id', '${profileId}', true)`,
  );
}

export async function withUserContext<T>(
  profileId: string | null,
  fn: (q: Querier) => Promise<T>,
): Promise<T> {
  const client: PoolClient = await getPool().connect();
  try {
    await openTransaction(client, profileId);

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
