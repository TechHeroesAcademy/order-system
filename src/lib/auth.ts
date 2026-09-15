import "server-only";
import { redirect } from "next/navigation";
import { headers } from "next/headers";
import { createClient } from "@/lib/supabase/server";
import { VERIFIED_PROFILE_HEADER } from "@/lib/supabase/middleware";
import type { Profile, UserRole } from "@/types/database";

/**
 * Current authenticated user's profile, or null if not logged in.
 *
 * Middleware (src/lib/supabase/middleware.ts) already runs on every request
 * that reaches here — it calls supabase.auth.getUser() (a verified round-trip
 * to the Auth API, not just a cookie read) and loads this exact profile row,
 * purely to decide whether the request is even allowed into the area it's
 * requesting. Re-doing both of those from scratch here, on every navigation,
 * used to double the auth cost of every single page load — a real
 * contributor to "moving between tabs feels slow", separate from the
 * notification-fetching fix in app-shell.tsx. So this reuses what
 * middleware already verified via a request header, and only falls back to
 * the real lookup when that header isn't present (middleware not having run
 * for this request, or a malformed value).
 */
export async function getCurrentProfile(): Promise<Profile | null> {
  const forwarded = (await headers()).get(VERIFIED_PROFILE_HEADER);
  if (forwarded) {
    try {
      return JSON.parse(forwarded) as Profile;
    } catch {
      // Fall through to the real lookup below.
    }
  }

  const supabase = await createClient();
  const {
    data: { user },
  } = await supabase.auth.getUser();
  if (!user) return null;

  const { data: profile } = await supabase
    .from("profiles")
    .select("*")
    .eq("id", user.id)
    .single();

  return (profile as Profile) ?? null;
}

/**
 * Server Component / Server Action guard. `proxy.ts` already keeps people out
 * of the wrong area in normal navigation, but Server Actions can be invoked
 * directly, so every privileged action re-checks here too (defense in depth
 * — the real boundary is Postgres RLS/RPCs either way).
 */
export async function requireRole(...roles: UserRole[]): Promise<Profile> {
  const profile = await getCurrentProfile();
  if (!profile || !profile.is_active) {
    redirect("/login");
  }
  if (!roles.includes(profile.role)) {
    redirect(`/${profile.role}`);
  }
  return profile;
}
