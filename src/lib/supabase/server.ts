import { createServerClient } from "@supabase/ssr";
import { cookies } from "next/headers";

/**
 * Supabase client for use in Server Components, Server Actions, and Route
 * Handlers. Must be created fresh per request (never module-level singleton).
 *
 * Server Components cannot write cookies, so `setAll` is wrapped in a
 * try/catch there — session refresh in that case is handled by `proxy.ts`,
 * which runs before the Server Component and can write cookies freely.
 */
export async function createClient() {
  const cookieStore = await cookies();

  return createServerClient(
    process.env.NEXT_PUBLIC_SUPABASE_URL!,
    process.env.NEXT_PUBLIC_SUPABASE_ANON_KEY!,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            for (const { name, value, options } of cookiesToSet) {
              cookieStore.set(name, value, options);
            }
          } catch {
            // Called from a Server Component — ignore. `proxy.ts` refreshes
            // the session cookie on every request instead.
          }
        },
      },
    },
  );
}
