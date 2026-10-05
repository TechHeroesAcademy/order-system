import "server-only";
import { Pool } from "pg";
import "./number-types";

declare global {
  var __orderSystemPool: Pool | undefined;
}

function isLocalHost(connectionString: string): boolean {
  try {
    const host = new URL(connectionString).hostname.replace(/^\[|\]$/g, "");
    return host === "localhost" || host === "127.0.0.1" || host === "::1";
  } catch {
    return false;
  }
}

function createPool(): Pool {
  const connectionString = process.env.DATABASE_URL;
  if (!connectionString) {
    throw new Error(
      "DATABASE_URL is not set. Use the pooled Neon connection string (the host containing '-pooler').",
    );
  }

  return new Pool({
    connectionString,
    ssl: isLocalHost(connectionString) ? false : { rejectUnauthorized: true },
    max: Number(process.env.DATABASE_POOL_MAX ?? 5),
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
    statement_timeout: 15_000,
    query_timeout: 15_000,
    application_name: "order-system",
  });
}

export function getPool(): Pool {
  if (globalThis.__orderSystemPool) return globalThis.__orderSystemPool;

  const created = createPool();

  created.on("error", (err) => {
    console.error("[db] idle client error (connection discarded):", err.message);
  });

  globalThis.__orderSystemPool = created;
  return created;
}
