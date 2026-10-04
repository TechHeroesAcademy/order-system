import "server-only";
import { redirect } from "next/navigation";
import { cookies, headers } from "next/headers";
import { createClient } from "@/lib/db/client";
import { VERIFIED_PROFILE_HEADER } from "@/lib/auth/proxy-session";
import { SESSION_COOKIE, verifySession } from "@/lib/auth/session";
import { decodeIdentityHeader } from "@/lib/auth/header-codec";
import type { Profile, UserRole } from "@/types/database";

/**
 * The signed-in person's profile, or null.
 *
 * src/lib/auth/proxy-session.ts has already verified the session for this
 * request and forwarded the identity in a header, so the common path is a
 * header read and nothing else — no network call, no database query. That
 * header is trustworthy only because the proxy deletes any client-supplied
 * copy before setting its own from a signature it just checked.
 *
 * It used to be worse than a header read: the proxy called GoTrue over the
 * network and queried profiles, and then this function did both again on
 * every navigation. Two round trips per page became zero.
 *
 * The fallback below covers a request the proxy did not run for — a Server
 * Action invoked directly, or a path the matcher excludes.
 */
export async function getCurrentProfile(): Promise<Profile | null> {
  const forwarded = decodeIdentityHeader<Profile>(
    (await headers()).get(VERIFIED_PROFILE_HEADER),
  );
  if (forwarded?.id) return forwarded;

  // The proxy did not run for this request (a Server Action invoked
  // directly, or a path the matcher excludes). Verify the cookie here
  // instead — an HMAC check, no network — and then load the full row under
  // RLS, because the cookie carries only identity and role.
  const session = await verifySession((await cookies()).get(SESSION_COOKIE)?.value);
  if (!session) return null;

  const db = await createClient();
  const { data: profile } = await db
    .from("profiles")
    .select("*")
    .eq("id", session.sub)
    .maybeSingle<Profile>();

  // profiles_select_self is `id = auth.uid()`, so this returns the row for a
  // deactivated account too — requireRole() below is what turns them away.
  // Deliberate: the account-inactive page needs to be able to say whose
  // account it is.
  return profile ?? null;
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
