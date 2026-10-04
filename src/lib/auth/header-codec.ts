/**
 * Encoding the verified identity so it can travel in an HTTP header.
 *
 * Not a nicety. HTTP header values are ByteStrings — one byte per character —
 * and every name in this system is Arabic. Writing the identity as raw JSON
 * threw
 *
 *   TypeError: Cannot convert argument to a ByteString because the character
 *   at index 73 has a value of 1571 which is greater than 255
 *
 * on the first request from an account called "أحمد المالك", and because the
 * proxy sets that header on every authenticated request, EVERY page returned
 * 500 for EVERY user. Found by starting the built app and loading a page,
 * which is the only thing that would have found it: it typechecks, it lints,
 * and the unit tests never construct a header.
 *
 * Base64url of the UTF-8 bytes is plain ASCII, so it is header-safe whatever
 * the name is. This is encoding, not security — the value is trustworthy
 * because the proxy strips any client-supplied copy before setting its own
 * from a signature it verified, and that is unchanged.
 */

export function encodeIdentityHeader(value: unknown): string {
  const bytes = new TextEncoder().encode(JSON.stringify(value));
  let binary = "";
  for (const b of bytes) binary += String.fromCharCode(b);
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function decodeIdentityHeader<T>(header: string | null): T | null {
  if (!header) return null;
  try {
    const padded = header.replace(/-/g, "+").replace(/_/g, "/");
    const binary = atob(padded + "=".repeat((4 - (padded.length % 4)) % 4));
    const bytes = new Uint8Array(binary.length);
    for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
    return JSON.parse(new TextDecoder().decode(bytes)) as T;
  } catch {
    // Anything unparseable is treated as "no forwarded identity", and the
    // callers fall back to verifying the cookie themselves. Never a partial
    // object: a half-decoded identity flowing into an authorization decision
    // is the failure mode worth paying a try/catch to avoid.
    return null;
  }
}
