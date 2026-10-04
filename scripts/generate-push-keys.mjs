/**
 * Generates the three push-notification secrets.
 *
 *   node scripts/generate-push-keys.mjs
 *
 * No dependencies — plain Node crypto, so it runs in a bare clone with no
 * `npm install`. DEPLOYMENT.md used to tell you to do this through web-push,
 * which meant installing the project first just to create three strings.
 *
 * RUN IT YOURSELF AND DO NOT PASTE THE OUTPUT ANYWHERE. The private key is
 * not recoverable and not re-derivable: whoever holds it can send push
 * notifications to every device subscribed to your app. That is not a data
 * breach — it reads nothing and grants no access — but a convincing fake "new
 * order" buzzing a driver's phone is its own problem.
 *
 * ONCE PER SYSTEM, NOT ONCE PER DEPLOY. Replacing the VAPID pair silently
 * invalidates every phone already registered: nobody receives a notification
 * again until each person re-enables it on their own device, and nothing
 * anywhere reports an error. Generate these on a first-ever setup, put them
 * in a password manager, and leave them alone.
 *
 * PUSH_WEBHOOK_SECRET is different — it can be rotated safely on its own,
 * but it lives in TWO places that must match exactly: the Vercel environment
 * variable, and the push_webhook_secret row in the app_settings table. Push
 * stops dead between the two changes, with no error anywhere, so change both
 * in the same sitting.
 */

import { generateKeyPairSync, randomBytes } from "node:crypto";

// VAPID is ECDSA on P-256 (prime256v1). The public key is the uncompressed
// point — the 0x04 prefix byte, then x, then y, 65 bytes in total — and the
// private key is the bare 32-byte scalar, both base64url. Exporting as JWK is
// the shortest route to those raw values without a library.
const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const pub = publicKey.export({ format: "jwk" });
const prv = privateKey.export({ format: "jwk" });

const uncompressedPoint = Buffer.concat([
  Buffer.from([0x04]),
  Buffer.from(pub.x, "base64url"),
  Buffer.from(pub.y, "base64url"),
]);

// Sanity-checked rather than assumed: a key of the wrong length is accepted
// by the environment variable and then fails at the moment a notification is
// sent, which is the worst time to find out.
if (uncompressedPoint.length !== 65) {
  throw new Error(`public key is ${uncompressedPoint.length} bytes, expected 65`);
}
if (Buffer.from(prv.d, "base64url").length !== 32) {
  throw new Error(`private key is ${Buffer.from(prv.d, "base64url").length} bytes, expected 32`);
}

console.log("");
console.log("Add these to Vercel (Settings -> Environment Variables),");
console.log("for Production, Preview AND Development:");
console.log("");
console.log("NEXT_PUBLIC_VAPID_PUBLIC_KEY=" + uncompressedPoint.toString("base64url"));
console.log("VAPID_PRIVATE_KEY=" + prv.d);
console.log("PUSH_WEBHOOK_SECRET=" + randomBytes(32).toString("base64url"));
console.log("VAPID_SUBJECT=mailto:you@yourbusiness.com");
console.log("");
console.log("Then put the SAME webhook secret in the database:");
console.log("");
console.log("  insert into public.app_settings (key, value) values");
console.log("    ('push_endpoint_url', 'https://YOUR-DOMAIN/api/push/dispatch'),");
console.log("    ('push_webhook_secret', 'THE PUSH_WEBHOOK_SECRET ABOVE')");
console.log("  on conflict (key) do update set value = excluded.value;");
console.log("");
console.log("Keep all of this in a password manager. The private key cannot be");
console.log("recovered, and replacing it later un-registers every phone.");
console.log("");
