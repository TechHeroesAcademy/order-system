import "server-only";
import type { QueryResultRow } from "pg";
import { getPool } from "./pool";
import { currentProfileId } from "./client";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/**
 * Runs several PARAMETERLESS reads in a single round trip.
 *
 * Why this exists, measured against the running app: a page that calls
 * seven report functions issued 24 statements, because each call was its
 * own transaction — open, query, commit. Every one of those is a network
 * exchange with Neon, so the page cost 21 exchanges of bookkeeping to do
 * seven reads.
 *
 * Postgres runs a multi-statement simple query as one implicit transaction
 * in one exchange, and returns one result per statement. So the whole page
 * becomes a single round trip. The identity is still set with
 * set_config(..., true), still transaction-local, and still expires with
 * the implicit transaction — the pooling property that made SET LOCAL
 * necessary is unchanged.
 *
 * THE RESTRICTION IS THE POINT. The simple protocol has no bind
 * parameters, so this accepts only statements with no values, and it
 * rejects anything containing a `$n` placeholder rather than quietly
 * sending it. A query that needs a value from a request keeps using the
 * extended protocol through withUserContext, where that value is bound and
 * never becomes SQL. Nothing user-supplied is interpolated here: the only
 * thing written into the text is the viewer's own profile id, which is
 * read back from a uuid column and is refused if it is not a uuid.
 *
 * Use it for a page's fixed set of reads. It is not a general escape from
 * parameter binding.
 */
export async function readBatch<T extends QueryResultRow[][]>(
  statements: readonly string[],
): Promise<T> {
  for (const s of statements) {
    if (/\$\d/.test(s)) {
      throw new Error(
        "readBatch takes parameterless statements only; use withUserContext for anything with a bound value",
      );
    }
    if (/;/.test(s.trim().replace(/;$/, ""))) {
      throw new Error("readBatch statements must be single statements");
    }
  }

  const profileId = await currentProfileId();
  if (profileId !== null && !UUID.test(profileId)) {
    throw new Error("profileId is not a uuid");
  }

  const identity = profileId ?? "";
  const text = [
    "begin",
    `select set_config('app.current_profile_id', '${identity}', true)`,
    ...statements.map((s) => s.replace(/;\s*$/, "")),
    "commit",
  ].join(";\n");

  const client = await getPool().connect();
  try {
    const res = await client.query(text);
    const results = Array.isArray(res) ? res : [res];
    // The first two results are the BEGIN and the set_config, the last is
    // the COMMIT. What the caller asked for sits between them.
    const rows = results.slice(2, 2 + statements.length).map((r) => r?.rows ?? []);
    return rows as unknown as T;
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
