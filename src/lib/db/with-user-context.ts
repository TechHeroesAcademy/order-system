import "server-only";
import type { PoolClient, QueryResult, QueryResultRow } from "pg";
import { getPool } from "./pool";

/**
 * The whole authorization model, in one function.
 *
 * Every RLS policy and every SECURITY DEFINER function in this schema asks
 * `auth.uid()` who is calling. On Supabase that read a JWT claim GoTrue
 * attached per request. Here it reads `app.current_profile_id`, a
 * transaction-local setting this function sets — see
 * neon/migrations/0001_auth_shim.sql, which changed what backs auth.uid()
 * and left all 108 of its call sites untouched.
 *
 * Three properties have to hold or the model is broken, and each one is a
 * line of code below rather than a convention:
 *
 *   1. ONE CHECKED-OUT CLIENT. The identity and the queries that depend on
 *      it must be on the same physical connection. Two pool.query() calls
 *      can land on two different connections.
 *
 *   2. INSIDE A TRANSACTION, SET LOCALLY. set_config(..., true) is
 *      transaction-scoped and resets at COMMIT. Measured on this schema: a
 *      session-level SET survived COMMIT and the next transaction on the
 *      same connection still saw the previous identity — on a pooled
 *      connection that is one request answering as another user. Neon's
 *      pooler is PgBouncer in transaction mode, so transaction-scoped is
 *      both safe and the only thing supported.
 *
 *   3. THE IDENTITY COMES FROM THE VERIFIED SESSION, NEVER FROM INPUT. The
 *      only caller that may pass a profile id is the session reader. A
 *      request body or header must never reach this parameter.
 *
 * Passing null is the unauthenticated case: auth.uid() is NULL, every
 * policy that compares a column to it is simply never true, and the four
 * tables with RLS and no policies stay unreachable. The schema fails closed
 * — verified, including that the role-guard helpers return false rather
 * than NULL (migration 0051, without which 49 guards fell open for exactly
 * this case).
 */

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

    // Parameterised, not interpolated. profileId reaches here from a signed
    // cookie, but a SQL-injection sink is a SQL-injection sink regardless of
    // how trusted the input is believed to be today.
    //
    // '' rather than null for an absent identity: current_setting(...) with
    // an empty string is what the shim's nullif() turns back into NULL, and
    // passing a real null here would make set_config itself fail.
    await client.query("select set_config('app.current_profile_id', $1, true)", [
      profileId ?? "",
    ]);

    const result = await fn({
      query: (text, values) => client.query(text, values as unknown[]),
    });

    await client.query("commit");
    return result;
  } catch (error) {
    // Best-effort: if the connection itself has gone the rollback also
    // fails, and the original error is the one worth reporting.
    try {
      await client.query("rollback");
    } catch {
      /* ignore */
    }
    throw error;
  } finally {
    client.release();
  }
}

/**
 * For the handful of paths that genuinely run before any session exists:
 * the login lookups, the owner bootstrap, and the push dispatch webhook.
 *
 * This is NOT a privilege escalation and nothing here bypasses RLS. It runs
 * with no identity at all, which is strictly less access than a logged-in
 * user has. Those paths work because each one calls a narrow SECURITY
 * DEFINER function that sees past RLS for one specific purpose and returns
 * one specific shape — auth_verify_login returns a status and a role, never
 * a hash; bootstrap_owner works only while no owner exists.
 *
 * That is deliberately different from Supabase's service-role key, which
 * this replaces: there is no credential here that can read everything.
 */
export function withoutUserContext<T>(fn: (q: Querier) => Promise<T>): Promise<T> {
  return withUserContext(null, fn);
}
