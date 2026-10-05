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

const ROLE_HOME: Record<UserRole, string> = {
  owner: "/owner",
  moderator: "/moderator",
  driver: "/driver",
  factory: "/login",
};

const AREA_ALLOWED_ROLES: { prefix: string; roles: UserRole[] }[] = [
  { prefix: "/owner", roles: ["owner"] },
  { prefix: "/moderator", roles: ["owner", "moderator"] },
  { prefix: "/driver", roles: ["owner", "driver"] },
];

const PUBLIC_PATHS = ["/", "/login", "/track", "/setup", "/order/new"];

export const VERIFIED_PROFILE_HEADER = "x-verified-profile";

function isPublic(pathname: string): boolean {
  return PUBLIC_PATHS.includes(pathname);
}

export async function updateSession(request: NextRequest): Promise<NextResponse> {
  request.headers.delete(VERIFIED_PROFILE_HEADER);

  const { pathname, search } = request.nextUrl;
  const session = await verifySession(request.cookies.get(SESSION_COOKIE)?.value);

  if (!session) {
    if (isPublic(pathname)) return NextResponse.next({ request });
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    url.search = `?next=${encodeURIComponent(pathname + search)}`;
    return NextResponse.redirect(url);
  }

  if (!session.active) {
    const url = request.nextUrl.clone();
    url.pathname = "/login";
    url.search = "?error=account_inactive";
    const response =
      pathname === "/login" ? NextResponse.next({ request }) : NextResponse.redirect(url);
    response.cookies.delete(SESSION_COOKIE);
    return response;
  }

  const role = session.role as UserRole;

  if (pathname === "/login" || pathname === "/setup") {
    const url = request.nextUrl.clone();
    url.pathname = ROLE_HOME[role] ?? "/login";
    url.search = "";
    return NextResponse.redirect(url);
  }

  const area = AREA_ALLOWED_ROLES.find((a) => pathname.startsWith(a.prefix));
  if (area && !area.roles.includes(role)) {
    const url = request.nextUrl.clone();
    url.pathname = ROLE_HOME[role] ?? "/login";
    url.search = "";
    return NextResponse.redirect(url);
  }

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

  response.headers.set("Cache-Control", "private, no-store, max-age=0");
  return response;
}
