import "server-only";
import { cookies } from "next/headers";
import {
  SESSION_COOKIE,
  sessionCookieOptions,
  signSession,
} from "./session";

/**
 * Issuing and clearing the session cookie.
 *
 * The only place in the application that sets it. Everything that signs
 * someone in — phone login, first-login password setup, owner bootstrap —
 * goes through here, so the cookie's flags are decided once in
 * sessionCookieOptions() and a new sign-in path cannot quietly drop
 * httpOnly or secure.
 */

export interface Identity {
  id: string;
  role: string;
  full_name: string;
}

/**
 * Called only after the database has authenticated the person —
 * auth_verify_login, auth_set_initial_password or bootstrap_owner returning
 * status 'ok'. Nothing here checks a password; by this point that has
 * already happened inside Postgres, and the hash never came out.
 */
export async function issueSession(identity: Identity): Promise<void> {
  const now = Math.floor(Date.now() / 1000);
  const token = await signSession({
    sub: identity.id,
    role: identity.role,
    name: identity.full_name,
    active: true,
    // Fresh sign-in, so the 14-day absolute ceiling starts now. Refreshes
    // carry this value forward rather than resetting it, which is what stops
    // a continuously-used session from living forever.
    iat: now,
  });

  (await cookies()).set(SESSION_COOKIE, token, sessionCookieOptions());
}

/** Sign-out, and the deactivated-account path. */
export async function clearSession(): Promise<void> {
  // Overwrite with an immediately-expired value as well as deleting, because
  // a delete alone can be ignored by an intermediary that has cached the
  // Set-Cookie. Belt and braces on the one operation a person expects to be
  // final.
  const jar = await cookies();
  jar.set(SESSION_COOKIE, "", sessionCookieOptions(0));
  jar.delete(SESSION_COOKIE);
}
