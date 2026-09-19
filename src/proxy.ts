import type { NextRequest } from "next/server";
import { updateSession } from "@/lib/supabase/middleware";

// Next.js 16 renamed `middleware.ts` to `proxy.ts` (same mechanism, new name).
export function proxy(request: NextRequest) {
  return updateSession(request);
}

export const config = {
  matcher: [
    /*
     * Run on everything except static assets and image optimization files.
     * We still want it on /login, /track, and the API-less app routes.
     *
     * .webmanifest is excluded alongside the image extensions for the same
     * reason favicon.ico is: app/manifest.ts (the PWA manifest, served at
     * /manifest.webmanifest) has to be reachable by the browser with no
     * session at all — a logged-out visitor on / or /login still needs to
     * be able to install the app — otherwise this middleware's PUBLIC_PATHS
     * check below (which doesn't know about metadata routes) 307s it to
     * /login, the browser gets an HTML page instead of JSON, and the
     * manifest silently fails to load for every unauthenticated page.
     *
     * /api/push is excluded for a related but distinct reason: it is called
     * by Postgres (the push trigger in migration 0041), not by a browser, so
     * it carries no session cookie at all. With this middleware in front of
     * it, the no-user branch below would 307 every push to /login and no
     * notification would ever be sent. It authenticates itself with a shared
     * secret instead — see the route handler. Excluding it also keeps the
     * two auth round-trips off a path that has no use for them.
     *
     * sw.js is excluded because the service worker must be fetchable with no
     * session — it is registered before anyone signs in, and a service
     * worker served as an HTML redirect fails to install.
     */
    "/((?!_next/static|_next/image|favicon.ico|api/push|sw\\.js|.*\\.(?:svg|png|jpg|jpeg|webp|webmanifest)$).*)",
  ],
};
