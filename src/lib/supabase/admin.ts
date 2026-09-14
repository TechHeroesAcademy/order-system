import "server-only";
import { createClient as createSupabaseClient } from "@supabase/supabase-js";

/**
 * Service-role client. Bypasses RLS entirely — never import this from a
 * Client Component or expose `SUPABASE_SERVICE_ROLE_KEY` to the browser.
 * Used only for privileged admin operations (creating staff accounts via
 * the Auth Admin API) from Server Actions that have already verified the
 * caller is an Owner.
 */
export function createAdminClient() {
  const url = process.env.NEXT_PUBLIC_SUPABASE_URL;
  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;

  if (!url || !serviceKey) {
    throw new Error(
      "SUPABASE_SERVICE_ROLE_KEY / NEXT_PUBLIC_SUPABASE_URL is missing — admin actions are unavailable.",
    );
  }

  return createSupabaseClient(url, serviceKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
}
