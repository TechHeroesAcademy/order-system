import "server-only";
import { cookies } from "next/headers";
import {
  SESSION_COOKIE,
  sessionCookieOptions,
  signSession,
} from "./session";

export interface Identity {
  id: string;
  role: string;
  full_name: string;
}

export async function issueSession(identity: Identity): Promise<void> {
  const now = Math.floor(Date.now() / 1000);
  const token = await signSession({
    sub: identity.id,
    role: identity.role,
    name: identity.full_name,
    active: true,
    iat: now,
  });

  (await cookies()).set(SESSION_COOKIE, token, sessionCookieOptions());
}

export async function clearSession(): Promise<void> {
  const jar = await cookies();
  jar.set(SESSION_COOKIE, "", sessionCookieOptions(0));
  jar.delete(SESSION_COOKIE);
}
