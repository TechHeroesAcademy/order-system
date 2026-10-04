import "server-only";
import { headers, cookies } from "next/headers";
import { DbClient } from "./query-builder";
import { SESSION_COOKIE, verifySession } from "@/lib/auth/session";
import { VERIFIED_PROFILE_HEADER } from "@/lib/auth/proxy-session";
import { decodeIdentityHeader } from "@/lib/auth/header-codec";

/**
 * A database handle for the current request, bound to the signed-in
 * person's identity.
 *
 * Drop-in for what `@/lib/supabase/server`'s createClient() returned: the
 * same `.from()` and `.rpc()` shapes, so the 88 call sites across
 * src/lib/data and src/lib/actions kept working with only their import
 * changed. What is different is underneath — a pg connection with
 * `app.current_profile_id` set for the transaction, instead of an HTTP call
 * to PostgREST with a JWT.
 *
 * The identity is resolved in two steps for the same reason the old code
 * read a header first: the proxy has already verified the session for this
 * request, and re-verifying costs an HMAC per call. The cookie fallback
 * covers the cases where the proxy did not run — a Server Action invoked
 * directly, and any path excluded by the matcher.
 *
 * Both sources are verified. The header is set by the proxy from a payload
 * it checked, and the proxy strips any client-supplied copy first; the
 * cookie path checks the signature here. Nothing unverified reaches
 * withUserContext.
 */
export async function createClient(): Promise<DbClient> {
  return new DbClient(await currentProfileId());
}

/**
 * The profile id for this request, or null when nobody is signed in.
 *
 * Exported because a few callers need the id without a database handle.
 */
export async function currentProfileId(): Promise<string | null> {
  const forwarded = decodeIdentityHeader<{ id?: unknown }>(
    (await headers()).get(VERIFIED_PROFILE_HEADER),
  );
  if (typeof forwarded?.id === "string" && forwarded.id.length > 0) return forwarded.id;

  const token = (await cookies()).get(SESSION_COOKIE)?.value;
  const session = await verifySession(token);
  return session?.sub ?? null;
}

/**
 * A handle with NO identity, for the three paths that run before a session
 * exists: the login lookups, the owner bootstrap, and the push dispatch
 * webhook (called by the database, carrying a shared secret, never a cookie).
 *
 * Named to match the `createAdminClient()` it replaces, because the call
 * sites are the same — but it is the opposite thing, and that is worth being
 * clear about. Supabase's admin client held the service-role key and could
 * read every row in the database. This one has no identity at all, which is
 * less access than any signed-in user. The pre-login paths work because each
 * one calls a narrow SECURITY DEFINER function that sees past RLS for one
 * purpose and returns one shape: auth_verify_login hands back a status and a
 * role, never a password hash, and bootstrap_owner only works while no owner
 * exists.
 *
 * So there is no longer any credential in this system that can read
 * everything. That was the main thing the service-role key cost us.
 */
export function createAdminClient(): DbClient {
  return new DbClient(null);
}
