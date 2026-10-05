import "server-only";
import { headers, cookies } from "next/headers";
import { DbClient } from "./query-builder";
import { SESSION_COOKIE, verifySession } from "@/lib/auth/session";
import { VERIFIED_PROFILE_HEADER } from "@/lib/auth/proxy-session";
import { decodeIdentityHeader } from "@/lib/auth/header-codec";

export async function createClient(): Promise<DbClient> {
  return new DbClient(await currentProfileId());
}

export async function currentProfileId(): Promise<string | null> {
  const forwarded = decodeIdentityHeader<{ id?: unknown }>(
    (await headers()).get(VERIFIED_PROFILE_HEADER),
  );
  if (typeof forwarded?.id === "string" && forwarded.id.length > 0) return forwarded.id;

  const token = (await cookies()).get(SESSION_COOKIE)?.value;
  const session = await verifySession(token);
  return session?.sub ?? null;
}

export function createAdminClient(): DbClient {
  return new DbClient(null);
}
