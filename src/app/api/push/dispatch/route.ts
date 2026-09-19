import { timingSafeEqual } from "node:crypto";
import { NextResponse } from "next/server";
import webpush from "web-push";
import { createAdminClient } from "@/lib/supabase/admin";
import type { UserRole } from "@/types/database";

/**
 * Turns one row of `notifications` into a push on the recipient's devices.
 *
 * Called by Postgres, not by a browser: the trigger in migration 0041 fires
 * an async pg_net POST carrying only the notification's id. Nothing about
 * this request comes from a signed-in session, which is why it authenticates
 * with a shared secret instead — and why /api/push is excluded from the auth
 * proxy's matcher (proxy.ts), since otherwise the proxy would see no session
 * and 307 this to /login before the handler ever ran.
 *
 * web-push signs with VAPID and encrypts the payload with Node's crypto, so
 * this has to be the Node runtime rather than edge.
 */
export const runtime = "nodejs";

/** Where tapping the notification should land, matching the bell's own routing. */
const ORDER_DETAIL_BASE: Record<UserRole, string> = {
  owner: "/owner/orders",
  moderator: "/moderator/orders",
  driver: "/driver/orders",
  factory: "/login",
};

/**
 * Compares without leaking length or content through timing. A plain `===`
 * on a secret returns as soon as two bytes differ, which is measurable over
 * enough requests; this is cheap insurance on the one check standing between
 * the open internet and sending notifications to staff phones.
 */
function secretMatches(provided: string | null, expected: string): boolean {
  if (!provided) return false;
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  // timingSafeEqual throws on a length mismatch, so that has to be handled
  // first — and separately, or the throw itself becomes the timing signal.
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

export async function POST(request: Request) {
  const secret = process.env.PUSH_WEBHOOK_SECRET;
  const publicKey = process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY;
  const privateKey = process.env.VAPID_PRIVATE_KEY;
  const subject = process.env.VAPID_SUBJECT;

  // Not configured is not an error worth alarming about: the migration may
  // be applied before the environment is set. 503 tells pg_net it failed
  // without implying the request was malformed.
  if (!secret || !publicKey || !privateKey || !subject) {
    return NextResponse.json({ error: "push not configured" }, { status: 503 });
  }

  if (!secretMatches(request.headers.get("x-push-secret"), secret)) {
    // Deliberately says nothing about which part was wrong.
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  let notificationId: string | undefined;
  try {
    const body = (await request.json()) as { notification_id?: string };
    notificationId = body.notification_id;
  } catch {
    return NextResponse.json({ error: "bad request" }, { status: 400 });
  }
  if (!notificationId) {
    return NextResponse.json({ error: "bad request" }, { status: 400 });
  }

  // Service role, because this reads another person's notification and their
  // device endpoints — there is no session here to scope RLS by, and this is
  // the one context in the system that legitimately needs a cross-user read.
  // Everything it can do is bounded by the id it was handed.
  const admin = createAdminClient();

  const { data: notification, error: notificationError } = await admin
    .from("notifications")
    .select("id, user_id, order_id, type, title, body")
    .eq("id", notificationId)
    .maybeSingle();

  if (notificationError) {
    return NextResponse.json({ error: "lookup failed" }, { status: 500 });
  }
  if (!notification) {
    // Already deleted, or an id that never existed. Nothing to do, and no
    // reason for pg_net to retry.
    return NextResponse.json({ ok: true, sent: 0, reason: "not found" });
  }

  const { data: recipient } = await admin
    .from("profiles")
    .select("role, is_active")
    .eq("id", notification.user_id)
    .maybeSingle();

  if (!recipient?.is_active) {
    return NextResponse.json({ ok: true, sent: 0, reason: "inactive recipient" });
  }

  const { data: subscriptions, error: subscriptionError } = await admin
    .from("push_subscriptions")
    .select("id, endpoint, p256dh, auth")
    .eq("user_id", notification.user_id);

  if (subscriptionError) {
    return NextResponse.json({ error: "lookup failed" }, { status: 500 });
  }
  if (!subscriptions?.length) {
    // The normal case for anyone who hasn't turned notifications on. Not a
    // failure — the in-app bell already has the notification.
    return NextResponse.json({ ok: true, sent: 0, reason: "no devices" });
  }

  webpush.setVapidDetails(subject, publicKey, privateKey);

  const role = (recipient.role ?? "driver") as UserRole;
  const url = notification.order_id
    ? `${ORDER_DETAIL_BASE[role]}/${notification.order_id}`
    : `/${role}`;

  const payload = JSON.stringify({
    title: notification.title,
    body: notification.body ?? "",
    url,
    // One live notification per order per device: a second message on an
    // order replaces the first rather than stacking up a column of them.
    tag: notification.order_id ? `order-${notification.order_id}` : notification.type,
    // A new order is the one thing a driver must not scroll past, so it
    // stays on screen until they acknowledge it. Chat does not — messages
    // arrive often enough that a sticky notification each time would be an
    // irritation rather than a help.
    requireInteraction: notification.type === "order_assigned",
  });

  const results = await Promise.allSettled(
    subscriptions.map((s) =>
      webpush.sendNotification(
        { endpoint: s.endpoint, keys: { p256dh: s.p256dh, auth: s.auth } },
        payload,
        { TTL: 60 * 60 * 12 },
      ),
    ),
  );

  // 404 and 410 from a push service mean the endpoint is gone for good —
  // the app was uninstalled, or permission was revoked. Those rows are
  // deleted rather than retried forever; anything else (a timeout, a 5xx at
  // the push service) is counted so a persistently broken device can be
  // spotted without throwing away one that is merely offline.
  const gone: string[] = [];
  const failed: string[] = [];
  const delivered: string[] = [];
  // Why each failure happened, echoed back in the response. pg_net stores
  // that response in net._http_response, so this is what makes a failure
  // diagnosable from the SQL editor. Without it the only signal is a count,
  // and "failed: 1" is indistinguishable between a wrong VAPID subject
  // (Apple is strict about it and answers BadJwtToken where Google shrugs),
  // a clock skew problem, and a push service simply being down.
  const errors: string[] = [];

  results.forEach((result, i) => {
    const subscription = subscriptions[i];
    if (result.status === "fulfilled") {
      delivered.push(subscription.id);
      return;
    }
    const reason = result.reason as { statusCode?: number; body?: string; message?: string } | undefined;
    const status = reason?.statusCode;
    if (status === 404 || status === 410) {
      gone.push(subscription.id);
      return;
    }
    failed.push(subscription.id);
    // Truncated because several of these land in one response, and a push
    // service can return a long HTML error page.
    const detail = (reason?.body || reason?.message || "unknown").slice(0, 300);
    // The host identifies which push service refused — Apple, Google and
    // Mozilla fail in different ways and for different reasons.
    let host = "unknown";
    try {
      host = new URL(subscription.endpoint).host;
    } catch {
      // A malformed endpoint is itself worth seeing in the output.
    }
    errors.push(`${host} → ${status ?? "no status"}: ${detail}`);
  });

  if (gone.length) {
    await admin.from("push_subscriptions").delete().in("id", gone);
  }
  if (delivered.length) {
    await admin
      .from("push_subscriptions")
      .update({ last_success_at: new Date().toISOString(), failure_count: 0 })
      .in("id", delivered);
  }
  if (failed.length) {
    // One round trip rather than one per row; the count is advisory, so a
    // lost increment under concurrency is not worth a transaction for.
    await admin.rpc("increment_push_failures", { p_ids: failed });
  }

  return NextResponse.json({
    ok: true,
    sent: delivered.length,
    removed: gone.length,
    failed: failed.length,
    // Present only when something went wrong, so a healthy response stays
    // small — pg_net keeps every one of these.
    ...(errors.length ? { errors } : {}),
  });
}
