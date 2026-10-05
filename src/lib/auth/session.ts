export const SESSION_COOKIE = "order_system_session";

const IDLE_SECONDS = 15 * 60;

const ABSOLUTE_SECONDS = 14 * 24 * 60 * 60;

export interface SessionPayload {
  sub: string;
  role: string;
  name: string;
  active: boolean;
  iat: number;
  exp: number;
}

function secretKeyMaterial(): Uint8Array {
  const secret = process.env.SESSION_SECRET;
  if (!secret || secret.length < 32) {
    throw new Error(
      "SESSION_SECRET is missing or shorter than 32 characters. Generate one with: openssl rand -base64 48",
    );
  }
  return new TextEncoder().encode(secret);
}

async function hmacKey(): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "raw",
    secretKeyMaterial() as unknown as ArrayBuffer,
    { name: "HMAC", hash: "SHA-256" },
    false,
    ["sign", "verify"],
  );
}

function b64urlEncode(bytes: Uint8Array): string {
  let s = "";
  for (const b of bytes) s += String.fromCharCode(b);
  return btoa(s).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function b64urlDecode(input: string): Uint8Array {
  const padded = input.replace(/-/g, "+").replace(/_/g, "/");
  const s = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
  const out = new Uint8Array(s.length);
  for (let i = 0; i < s.length; i++) out[i] = s.charCodeAt(i);
  return out;
}

export async function signSession(
  payload: Omit<SessionPayload, "exp"> & { exp?: number },
): Promise<string> {
  const now = Math.floor(Date.now() / 1000);
  const full: SessionPayload = {
    ...payload,
    exp: Math.min(now + IDLE_SECONDS, payload.iat + ABSOLUTE_SECONDS),
  };

  const body = b64urlEncode(new TextEncoder().encode(JSON.stringify(full)));
  const key = await hmacKey();
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(body));
  return `${body}.${b64urlEncode(new Uint8Array(sig))}`;
}

export async function verifySession(token: string | undefined): Promise<SessionPayload | null> {
  if (!token) return null;

  const dot = token.lastIndexOf(".");
  if (dot <= 0) return null;

  const body = token.slice(0, dot);
  const sig = token.slice(dot + 1);

  try {
    const key = await hmacKey();
    const ok = await crypto.subtle.verify(
      "HMAC",
      key,
      b64urlDecode(sig) as unknown as ArrayBuffer,
      new TextEncoder().encode(body),
    );
    if (!ok) return null;

    const parsed: unknown = JSON.parse(new TextDecoder().decode(b64urlDecode(body)));
    if (!isSessionPayload(parsed)) return null;

    const now = Math.floor(Date.now() / 1000);
    if (parsed.exp <= now) return null;
    if (parsed.iat + ABSOLUTE_SECONDS <= now) return null;

    return parsed;
  } catch {
    return null;
  }
}

function isSessionPayload(v: unknown): v is SessionPayload {
  if (!v || typeof v !== "object") return false;
  const o = v as Record<string, unknown>;
  return (
    typeof o.sub === "string" &&
    o.sub.length > 0 &&
    typeof o.role === "string" &&
    typeof o.name === "string" &&
    typeof o.active === "boolean" &&
    typeof o.iat === "number" &&
    typeof o.exp === "number"
  );
}

export function sessionCookieOptions(maxAgeSeconds = IDLE_SECONDS) {
  return {
    httpOnly: true,
    secure: process.env.NODE_ENV === "production",
    sameSite: "lax" as const,
    path: "/",
    maxAge: maxAgeSeconds,
  };
}

export function shouldRefresh(payload: SessionPayload): boolean {
  const now = Math.floor(Date.now() / 1000);
  return payload.exp - now < IDLE_SECONDS / 2;
}

export const SESSION_IDLE_SECONDS = IDLE_SECONDS;
export const SESSION_ABSOLUTE_SECONDS = ABSOLUTE_SECONDS;
