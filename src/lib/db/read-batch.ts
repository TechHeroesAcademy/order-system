import "server-only";
import type { QueryResultRow } from "pg";
import { getPool } from "./pool";
import { currentProfileId } from "./client";

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

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
