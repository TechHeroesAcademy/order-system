import type { NextRequest } from "next/server";
import { updateSession } from "@/lib/auth/proxy-session";

export function proxy(request: NextRequest) {
  return updateSession(request);
}

export const config = {
  matcher: [
    "/((?!_next/static|_next/image|favicon.ico|api/push|sw\\.js|.*\\.(?:svg|png|jpg|jpeg|webp|webmanifest)$).*)",
  ],
};
