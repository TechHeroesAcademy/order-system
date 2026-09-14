import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";
import type { UserRole } from "@/types/database";

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

const PUBLIC_PATHS = ["/", "/login", "/track"];

/**
 * Runs on every request (see `proxy.ts`). Refreshes the Supabase session
 * cookie and enforces coarse role-based route access — the real
 * authorization boundary is Postgres RLS + the workflow RPCs, this is a
 * user-experience layer that keeps people out of areas that aren't theirs
 * and bounces logged-out users to /login.
 */
export async function updateSession(request: NextRequest) {
  let response = NextResponse.next({ request });

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
          response = NextResponse.next({ request });
          for (const { name, value, options } of cookiesToSet) {
            response.cookies.set(name, value, options);
          }
          for (const [key, headerValue] of Object.entries(headers)) {
            response.headers.set(key, headerValue);
          }
        },
      },
    },
  );

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
    return response;
  }

  // Logged in: look up their role once, then enforce area access.
  const { data: profile } = await supabase
    .from("profiles")
    .select("role, is_active")
    .eq("id", user.id)
    .single();

  const role = profile?.role as UserRole | undefined;

  if (!profile || !profile.is_active || !role) {
    // No profile yet, or deactivated — send to login with an explanation.
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    url.searchParams.set("error", "account_inactive");
    return NextResponse.redirect(url);
  }

  if (pathname === "/login") {
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

  return response;
}
