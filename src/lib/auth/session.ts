/**
 * The session cookie.
 *
 * No "server-only" marker and no Node imports: this module is also loaded by
 * src/proxy.ts, which runs on the Edge runtime. Everything here uses Web
 * Crypto, which both runtimes have.
 *
 * WHAT REPLACED WHAT
 *
 * Before, every single request made the proxy call GoTrue over the network
 * to verify the session and then query `profiles` — two round trips per
 * request, including for a page that renders nothing. Now the proxy verifies
 * an HMAC locally and reads the role out of the cookie. Nothing in the
 * request path touches the database until the page itself asks for data.
 *
 * SIGNED, NOT ENCRYPTED, AND WHY THAT IS FINE
 *
 * The payload is readable by whoever holds the cookie: profile id, role,
 * display name, active flag, and two timestamps. None of that is a secret
 * from the person it describes — they can see their own name and role on
 * every page. What matters is that it cannot be *changed*, and that is what
 * the HMAC is for. Encrypting it as well would hide the role from the user
 * who already knows it, in exchange for a second thing to get wrong.
 *
 * THE TRADEOFF TO KNOW ABOUT
 *
 * Because the proxy no longer reads the database, deactivating an account
 * takes effect at the next cookie refresh rather than the next request. Two
 * things bound that: the cookie is short-lived and rolling (15 minutes), so
 * a deactivation lands within a quarter of an hour; and the database itself
 * refuses a deactivated account regardless of what a cookie says, because
 * current_user_role() now requires is_active (migration 0051). The second is
 * the real control — a stale cookie buys someone a page shell with no data
 * in it.
 */

export const SESSION_COOKIE = "order_system_session";

/** Rolling: re-issued on every verified request, so active use never logs out. */
const IDLE_SECONDS = 15 * 60;

/**
 * The hard ceiling, regardless of activity. A stolen cookie is useless after
 * this no matter how busily it is used, which a purely rolling expiry would
 * never achieve.
 */
const ABSOLUTE_SECONDS = 14 * 24 * 60 * 60;

export interface SessionPayload {
  /** profiles.id — the value that becomes auth.uid(). */
  sub: string;
  role: string;
  name: string;
  active: boolean;
  /** First issued (seconds). Enforces the absolute ceiling across refreshes. */
  iat: number;
  /** This cookie's own expiry (seconds). */
  exp: number;
}

function secretKeyMaterial(): Uint8Array {
  const secret = process.env.SESSION_SECRET;
  if (!secret || secret.length < 32) {
    // Loud and early. A short or missing secret is a forgeable session, so
    // this must never fall back to a default — an app that boots with a
    // development secret in production is the failure this prevents.
    throw new Error(
      "SESSION_SECRET is missing or shorter than 32 characters. Generate one with: openssl rand -base64 48",
    );
  }
  return new TextEncoder().encode(secret);
}

async function hmacKey(): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    secretKeyMaterial() as unknown as ArrayBuffer,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

function b64urlEncode(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlDecode(input: string): Uint8Array {
  const padded = input.replace(/-/g, "+").replace(/_/g, "/");
  const s = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

/** `<base64url payload>.<base64url hmac>` */
export async function signSession(
  payload: Omit<SessionPayload, "exp"> & { exp?: number },
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const full: SessionPayload = {
    ...payload,
    // Never past the absolute ceiling, even on a refresh. This is what makes
    // the 14 days a real limit rather than a suggestion.
    exp: Math.min(now + IDLE_SECONDS, payload.iat + ABSOLUTE_SECONDS),
  };

  const body = b64urlEncode(new TextEncoder().encode(JSON.stringify(full)));
  const key = await hmacKey();
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return `${body}.${b64urlEncode(new Uint8Array(sig))}`;
}

/**
 * Returns the payload only if the signature verifies AND it has not expired.
 * Null for anything else — a tampered payload, a cookie signed with an old
 * secret, truncated input, or junk.
 *
 * crypto.subtle.verify is a constant-time comparison. Comparing the
 * signatures as strings would leak, through timing, how much of a forged
 * signature was correct.
 */
export async function verifySession(token: string | undefined): Promise<SessionPayload | null> {
  if (!token) return null;

  const dot = token.lastIndexOf(".");
  if (dot <= 0) return null;

  const body = token.slice(0, dot);
  const sig = token.slice(dot + 1);

  try {
    const key = await hmacKey();
    const ok = await crypto.subtle.verify(
      "HMAC",
      key,
      b64urlDecode(sig) as unknown as ArrayBuffer,
      new TextEncoder().encode(body),
    );
    if (!ok) return null;

    const parsed: unknown = JSON.parse(new TextDecoder().decode(b64urlDecode(body)));
    if (!isSessionPayload(parsed)) return null;

    const now = Math.floor(Date.now() / 1000);
    if (parsed.exp <= now) return null;
    if (parsed.iat + ABSOLUTE_SECONDS <= now) return null;

    return parsed;
  } catch {
    // Malformed base64, malformed JSON, a bad key length. All of it is just
    // "not a valid session".
    return null;
  }
}

/**
 * Checked field by field rather than cast. The signature already proves we
 * wrote it, but a cookie issued by an older version of this code could have
 * a different shape, and `as SessionPayload` would turn that into undefined
 * fields flowing into an authorization decision.
 */
function isSessionPayload(v: unknown): v is SessionPayload {
  if (!v || typeof v !== "object") return false;
  const o = v as Record<string, unknown>;
  return (
    typeof o.sub === "string" &&
    o.sub.length > 0 &&
    typeof o.role === "string" &&
    typeof o.name === "string" &&
    typeof o.active === "boolean" &&
    typeof o.iat === "number" &&
    typeof o.exp === "number"
  );
}

/**
 * One definition of the cookie's flags, used by every place that sets it, so
 * a sign-in path cannot accidentally drop httpOnly.
 *
 * httpOnly — no script can read it, so an injected script cannot steal the
 *   session even if one got in.
 * secure — HTTPS only, except on localhost where there is no HTTPS to have.
 * sameSite lax — not sent on cross-site POSTs, which is CSRF protection for
 *   the Server Actions; lax rather than strict so that following a link into
 *   the app from WhatsApp still arrives signed in.
 */
export function sessionCookieOptions(maxAgeSeconds = IDLE_SECONDS) {
  return {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax" as const,
    path: "/",
    maxAge: maxAgeSeconds,
  };
}

/** True when the cookie is over halfway to expiry and worth re-issuing. */
export function shouldRefresh(payload: SessionPayload): boolean {
  const now = Math.floor(Date.now() / 1000);
  return payload.exp - now < IDLE_SECONDS / 2;
}

export const SESSION_IDLE_SECONDS = IDLE_SECONDS;
export const SESSION_ABSOLUTE_SECONDS = ABSOLUTE_SECONDS;
