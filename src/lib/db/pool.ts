import "server-only";
import { Pool } from "pg";

/**
 * The one connection pool for the whole application.
 *
 * Module scope on purpose: Next.js reuses the module across requests in a
 * warm serverless instance, so this is created once per instance rather
 * than once per request. A pool per request would open and close a TCP
 * connection on every page view, which is the single most expensive thing
 * you can do to a hosted Postgres.
 *
 * DATABASE_URL must be the POOLED Neon endpoint (the host with `-pooler` in
 * it). Neon's pooler is PgBouncer in transaction mode, which is why
 * withUserContext() sets the request's identity with SET LOCAL inside a
 * transaction and never with a session-level SET — measured directly, a
 * session-level SET survives COMMIT and leaks into whatever request gets
 * that connection next.
 *
 * Schema migrations and pg_dump want DATABASE_URL_UNPOOLED instead; they
 * need session-level features the pooler refuses.
 */

declare global {
  var __orderSystemPool: Pool | undefined;
}

/**
 * True only for a loopback address. Anything else — a LAN address, a VPN
 * host, a tunnel, a hostname that happens to resolve to 127.0.0.1 — gets
 * full certificate verification.
 */
function isLocalHost(connectionString: string): boolean {
  try {
    const host = new URL(connectionString).hostname.replace(/^\[|\]$/g, "");
    return host === "localhost" || host === "127.0.0.1" || host === "::1";
  } catch {
    // Unparseable: assume remote and verify. Failing towards more security.
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
    // Verified TLS everywhere except a database on this machine, which does
    // not speak TLS at all and has no network to intercept.
    //
    // The exemption is by HOST, not by NODE_ENV: a production build pointed
    // at a remote database still verifies, and the only way to switch
    // verification off is to point the app at your own loopback address.
    // NEVER set rejectUnauthorized to false here — that accepts any
    // certificate, including an attacker's, which is worse than no TLS
    // because it looks encrypted.
    //
    // Found the hard way: without the exemption, every query against a
    // local Postgres failed with "the server does not support SSL
    // connections", and because ownerExists() fails closed on error, the
    // /setup page reported the system was already set up instead of
    // reporting that the database was unreachable.
    ssl: isLocalHost(connectionString) ? false : { rejectUnauthorized: true },
    // Small on purpose. Every Vercel instance keeps its own pool, so the
    // real connection count is this times the number of warm instances, and
    // it is easy to exhaust a small Postgres with a generous-looking number.
    max: Number(process.env.DATABASE_POOL_MAX ?? 5),
    // Neon scales compute to zero when idle; a connection held open past
    // that is dead and fails on first use. Releasing early costs one
    // reconnect on the next request instead.
    idleTimeoutMillis: 30_000,
    connectionTimeoutMillis: 10_000,
    // A query that has not finished in 15s is not going to help the person
    // waiting for it, and holding the connection makes the next request
    // worse. Enforced server-side as well, below.
    statement_timeout: 15_000,
    query_timeout: 15_000,
    application_name: "order-system",
  });
}

/**
 * Created on first use, not at import.
 *
 * `next build` evaluates every route module to collect its config, with no
 * runtime environment present. A pool built at module scope therefore threw
 * "DATABASE_URL is not set" during the build and failed it — the app
 * compiled fine and then could not be packaged. Deferring means the
 * connection string is only required when something actually wants a
 * connection, which is at request time, where it exists.
 *
 * Cached on globalThis rather than in a module-level variable because Next
 * hot-reloads modules in development: a plain variable would leak a whole
 * pool on every edit until Postgres started refusing connections.
 */
export function getPool(): Pool {
  if (globalThis.__orderSystemPool) return globalThis.__orderSystemPool;

  const created = createPool();

  // An idle client erroring — Neon scaling its compute to zero, a network
  // blip — must not take the process down. The pool discards that client and
  // the next request gets a fresh one. Without this handler the error is an
  // unhandled 'error' event on an EventEmitter, which crashes Node.
  created.on("error", (err) => {
    console.error("[db] idle client error (connection discarded):", err.message);
  });

  globalThis.__orderSystemPool = created;
  return created;
}
