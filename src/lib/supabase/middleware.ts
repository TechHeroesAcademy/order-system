import { createServerClient, type CookieOptions } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import type { Profile, UserRole } from "@/types/database";

const ROLE_HOME: Record<UserRole, string> = {
  owner: "/owner",
  moderator: "/moderator",
  driver: "/driver",
  factory: "/factory",
};

const AREA_ALLOWED_ROLES: { prefix: string; roles: UserRole[] }[] = [
  { prefix: "/owner", roles: ["owner"] },
  { prefix: "/moderator", roles: ["owner", "moderator"] },
  { prefix: "/driver", roles: ["owner", "driver"] },
  { prefix: "/factory", roles: ["owner", "factory"] },
];

const PUBLIC_PATHS = ["/", "/login", "/track", "/setup", "/order/new"];

/**
 * Middleware already does exactly what every server-rendered route needs
 * for auth: it calls supabase.auth.getUser() (the one call that actually
 * verifies the session against the Auth server — reading the cookie alone
 * isn't trustworthy) and loads the caller's profile row, purely to decide
 * whether this request is allowed into the area it's requesting. Before this
 * fix, requireRole()/getCurrentProfile() (called by every role layout, on
 * every single navigation) repeated both of those steps from scratch —
 * another auth.getUser() round-trip to Supabase's Auth API, plus another
 * `profiles` query — even though middleware had just verified the exact
 * same thing a moment earlier in the exact same request. That doubling was
 * a real, measurable part of "moving between tabs is slow", independent of
 * the notification-fetching fix in app-shell.tsx.
 *
 * Fix: middleware forwards the profile row it already verified as a request
 * header, and getCurrentProfile() (src/lib/auth.ts) reads that header first,
 * only falling back to its own auth.getUser() + query when the header is
 * missing (e.g. a Server Action edge case, or middleware not having run).
 *
 * This header is only ever trustworthy because it is *always* set here,
 * explicitly, from a value middleware itself just verified — never forwarded
 * from whatever the client sent. `request.headers.delete()` at the very top
 * strips any client-supplied copy before anything else runs, so there's no
 * path where an unverified value could reach the app.
 */
export const VERIFIED_PROFILE_HEADER = "x-verified-profile";

export async function updateSession(request: NextRequest) {
  // Strip any client-supplied value up front — everything below either
  // re-sets this from a value we just verified, or leaves it unset.
  request.headers.delete(VERIFIED_PROFILE_HEADER);

  // Cookie writes (session refresh) and the cache-control headers Supabase
  // requires alongside them are queued here instead of being applied to a
  // response object immediately, since the final response also needs to
  // carry the (possibly later-set) verified-profile request header — and
  // `NextResponse.next({ request })` has to be called again after that
  // header is set, which would otherwise throw away anything already
  // applied to an earlier response object.
  const queuedCookies: { name: string; value: string; options: CookieOptions }[] = [];
  let queuedCacheHeaders: Record<string, string> = {};

  const supabase = createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet, headers) {
          for (const { name, value } of cookiesToSet) {
            request.cookies.set(name, value);
          }
          queuedCookies.push(...cookiesToSet);
          queuedCacheHeaders = { ...queuedCacheHeaders, ...headers };
        },
      },
    },
  );

  function buildResponse() {
    const res = NextResponse.next({ request });
    for (const { name, value, options } of queuedCookies) {
      res.cookies.set(name, value, options);
    }
    for (const [key, value] of Object.entries(queuedCacheHeaders)) {
      res.headers.set(key, value);
    }
    return res;
  }

  const {
    data: { user },
  } = await supabase.auth.getUser();

  const pathname = request.nextUrl.pathname;
  const isPublic = PUBLIC_PATHS.some((p) => pathname === p || pathname.startsWith(p + "/"));

  if (!user) {
    if (!isPublic) {
      const url = request.nextUrl.clone();
      url.pathname = "/login";
      url.searchParams.set("next", pathname);
      return NextResponse.redirect(url);
    }
    return buildResponse();
  }

  // Logged in: look up their full profile once — both to enforce area
  // access below and to forward downstream so layouts/pages don't have to
  // look it up again.
  const { data: profile } = await supabase.from("profiles").select("*").eq("id", user.id).single<Profile>();

  const role = profile?.role;

  if (!profile || !profile.is_active || !role) {
    // No profile yet, or deactivated — send to login with an explanation.
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    url.searchParams.set("error", "account_inactive");
    return NextResponse.redirect(url);
  }

  if (pathname === "/login" || pathname === "/setup") {
    const url = request.nextUrl.clone();
    url.pathname = ROLE_HOME[role];
    return NextResponse.redirect(url);
  }

  const area = AREA_ALLOWED_ROLES.find((a) => pathname.startsWith(a.prefix));
  if (area && !area.roles.includes(role)) {
    const url = request.nextUrl.clone();
    url.pathname = ROLE_HOME[role];
    return NextResponse.redirect(url);
  }

  request.headers.set(VERIFIED_PROFILE_HEADER, JSON.stringify(profile));
  return buildResponse();
}
