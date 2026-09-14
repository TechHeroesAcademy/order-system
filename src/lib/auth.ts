import "server-only";
import { redirect } from "next/navigation";
import { createClient } from "@/lib/supabase/server";
import type { Profile, UserRole } from "@/types/database";

/** Current authenticated user's profile, or null if not logged in. */
export async function getCurrentProfile(): Promise<Profile | null> {
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
