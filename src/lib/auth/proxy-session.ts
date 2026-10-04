import { NextResponse, type NextRequest } from "next/server";
import type { UserRole } from "@/types/database";
import {
  SESSION_COOKIE,
  sessionCookieOptions,
  shouldRefresh,
  signSession,
  verifySession,
} from "./session";
import { encodeIdentityHeader } from "./header-codec";

/**
 * What runs on every request: session verification and area access.
 *
 * Replaces src/lib/supabase/middleware.ts. That version called GoTrue over
 * the network and then queried `profiles`, on every single request. This one
 * verifies an HMAC locally. No network, no database, no pool — which also
 * means it still works on the Edge runtime, where `pg` cannot run at all.
 *
 * The contract downstream is unchanged: the verified identity is forwarded
 * in the same x-verified-profile header, and src/lib/auth.ts reads it the
 * same way. Only the verification underneath is different.
 */

const ROLE_HOME: Record<UserRole, string> = {
  owner: "/owner",
  moderator: "/moderator",
  driver: "/driver",
  // Factories stopped being accounts in migration 0033. The role survives on
  // historical records only, so anyone somehow still carrying it goes to the
  // login screen rather than a route that no longer exists.
  factory: "/login",
};

const AREA_ALLOWED_ROLES: { prefix: string; roles: UserRole[] }[] = [
  { prefix: "/owner", roles: ["owner"] },
  { prefix: "/moderator", roles: ["owner", "moderator"] },
  { prefix: "/driver", roles: ["owner", "driver"] },
];

const PUBLIC_PATHS = ["/", "/login", "/track", "/setup", "/order/new"];

/**
 * The header carrying the verified identity to Server Components and Server
 * Actions, so they do not each re-verify.
 *
 * It is trustworthy for exactly one reason: it is deleted from the incoming
 * request before anything else runs, and only ever re-set from a payload
 * whose signature this file just checked. A client that sends its own copy
 * has it discarded. That delete is the single most important line here —
 * without it, `x-verified-profile: {"role":"owner"}` from curl would be an
 * admin account.
 */
export const VERIFIED_PROFILE_HEADER = "x-verified-profile";

function isPublic(pathname: string): boolean {
  return PUBLIC_PATHS.includes(pathname);
}

export async function updateSession(request: NextRequest): Promise<NextResponse> {
  // Before anything. See the note above.
  request.headers.delete(VERIFIED_PROFILE_HEADER);

  const { pathname, search } = request.nextUrl;
  const session = await verifySession(request.cookies.get(SESSION_COOKIE)?.value);

  // ── not signed in ─────────────────────────────────────────────────────
  if (!session) {
    if (isPublic(pathname)) return NextResponse.next({ request });
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    url.search = `?next=${encodeURIComponent(pathname + search)}`;
    return NextResponse.redirect(url);
  }

  // ── signed in but switched off ────────────────────────────────────────
  //
  // The database refuses a deactivated account on its own (migration 0051
  // made current_user_role() require is_active), so this is the courteous
  // half: say so and clear the cookie rather than letting them walk into
  // empty pages.
  if (!session.active) {
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    url.search = "?error=account_inactive";
    // Guard against redirecting /login to /login forever — the bug the old
    // middleware had, which turned a deactivated account into
    // ERR_TOO_MANY_REDIRECTS instead of a login page.
    const response =
      pathname === "/login" ? NextResponse.next({ request }) : NextResponse.redirect(url);
    response.cookies.delete(SESSION_COOKIE);
    return response;
  }

  const role = session.role as UserRole;

  // ── already signed in, standing on a sign-in page ─────────────────────
  if (pathname === "/login" || pathname === "/setup") {
    const url = request.nextUrl.clone();
    url.pathname = ROLE_HOME[role] ?? "/login";
    url.search = "";
    return NextResponse.redirect(url);
  }

  // ── area access ───────────────────────────────────────────────────────
  const area = AREA_ALLOWED_ROLES.find((a) => pathname.startsWith(a.prefix));
  if (area && !area.roles.includes(role)) {
    const url = request.nextUrl.clone();
    url.pathname = ROLE_HOME[role] ?? "/login";
    url.search = "";
    return NextResponse.redirect(url);
  }

  // ── forward the verified identity ─────────────────────────────────────
  //
  // Only the four fields the application reads. The cookie is the whole
  // profile as far as the proxy is concerned, but pages that need the rest
  // of the row (phone, areas, timestamps) query for it under RLS, where the
  // database decides what they may see — rather than trusting a cookie for
  // anything beyond identity and role.
  // Base64url, not raw JSON. Header values are one byte per character and
  // every name here is Arabic, so raw JSON threw on the first request and
  // turned every authenticated page into a 500. See header-codec.ts.
  request.headers.set(
    VERIFIED_PROFILE_HEADER,
    encodeIdentityHeader({
      id: session.sub,
      role: session.role,
      full_name: session.name,
      is_active: session.active,
    }),
  );

  const response = NextResponse.next({ request });

  // Rolling expiry: re-issue once a cookie is over halfway through its life,
  // so someone working continuously is never logged out mid-task, while an
  // abandoned session still dies in 15 minutes. iat is carried over, which
  // is what keeps the 14-day absolute ceiling absolute.
  if (shouldRefresh(session)) {
    const refreshed = await signSession({
      sub: session.sub,
      role: session.role,
      name: session.name,
      active: session.active,
      iat: session.iat,
    });
    response.cookies.set(SESSION_COOKIE, refreshed, sessionCookieOptions());
  }

  // A page rendered for one signed-in person must never be served to
  // another from a shared cache.
  response.headers.set("Cache-Control", "private, no-store, max-age=0");
  return response;
}
