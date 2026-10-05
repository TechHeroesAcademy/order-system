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

/**
 * Opens the transaction and sets the request's identity in ONE round trip.
 *
 * This used to be two statements, and every query in the app paid for both.
 * Measured against the running app: a page doing 9 reads issued 36
 * statements, 27 of them BEGIN / set_config / COMMIT. Each one is a network
 * round trip to Neon, so three quarters of the database traffic on every
 * page view was transaction bookkeeping.
 *
 * Postgres wraps a multi-statement simple query in an implicit transaction
 * and runs it in one exchange, so BEGIN and the set_config can travel
 * together. The simple protocol has no bind parameters, which is why the id
 * is checked against a UUID pattern and refused otherwise rather than
 * escaped — every profile id in this system is a uuid column read back from
 * the database, so anything that is not one is a bug, not a value to make
 * safe. The empty-identity case (no session) is a literal with nothing
 * interpolated at all.
 *
 * The main query still goes through the extended protocol with its values
 * bound, exactly as before; nothing about how user data reaches SQL changes.
 */
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
