import "server-only";
import { redirect } from "next/navigation";
import { cookies, headers } from "next/headers";
import { createClient } from "@/lib/db/client";
import { VERIFIED_PROFILE_HEADER } from "@/lib/auth/proxy-session";
import { SESSION_COOKIE, verifySession } from "@/lib/auth/session";
import { decodeIdentityHeader } from "@/lib/auth/header-codec";
import type { Profile, UserRole } from "@/types/database";

export async function getCurrentProfile(): Promise<Profile | null> {
  const forwarded = decodeIdentityHeader<Profile>(
    (await headers()).get(VERIFIED_PROFILE_HEADER),
  );
  if (forwarded?.id) return forwarded;

  const session = await verifySession((await cookies()).get(SESSION_COOKIE)?.value);
  if (!session) return null;

  const db = await createClient();
  const { data: profile } = await db
    .from("profiles")
    .select("*")
    .eq("id", session.sub)
    .maybeSingle<Profile>();

  return profile ?? null;
}

export async function requireRole(...roles: UserRole[]): Promise<Profile> {
  const profile = await getCurrentProfile();
  if (!profile || !profile.is_active) {
    redirect("/login");
  }
  if (!roles.includes(profile.role)) {
    // profiles has check (role <> 'factory') and there is no /factory route,
    // so a historical factory profile would be redirected into a 404.
    redirect(profile.role === "factory" ? "/login" : `/${profile.role}`);
  }
  return profile;
}
