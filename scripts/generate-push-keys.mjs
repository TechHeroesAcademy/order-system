import { generateKeyPairSync, randomBytes } from "node:crypto";

const { publicKey, privateKey } = generateKeyPairSync("ec", { namedCurve: "prime256v1" });
const pub = publicKey.export({ format: "jwk" });
const prv = privateKey.export({ format: "jwk" });

const uncompressedPoint = Buffer.concat([
  Buffer.from([0x04]),
  Buffer.from(pub.x, "base64url"),
  Buffer.from(pub.y, "base64url"),
]);

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
