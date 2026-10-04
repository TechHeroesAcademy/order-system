import { timingSafeEqual } from "node:crypto";
import { NextResponse } from "next/server";
import webpush from "web-push";
import { createAdminClient } from "@/lib/db/client";
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

/** One row per registered device; the notification fields repeat across them. */
interface PushTarget {
  notification_id: string;
  order_id: string | null;
  notification_type: string;
  title: string;
  body: string | null;
  recipient_role: UserRole | null;
  recipient_active: boolean;
  subscription_id: string | null;
  endpoint: string | null;
  p256dh: string | null;
  auth_secret: string | null;
}

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

  // No identity at all, and one SECURITY DEFINER function instead of three
  // cross-user reads.
  //
  // This route is called by the database, not a browser, so it has no
  // session — and it has to read one person's notification, their profile
  // and their registered devices, which is the only deliberate cross-user
  // read in the system. Under Supabase a service-role key made that work by
  // ignoring row-level security everywhere.
  //
  // With that key gone, the three queries this used to make would each
  // return zero rows and NO error: notifications_select_own and
  // push_subscriptions_select_own both compare user_id to auth.uid(), which
  // is NULL here. The route would answer {"sent":0,"reason":"not found"}
  // forever and nothing would reach a phone — invisible, because the in-app
  // bell keeps working. push_dispatch_payload (migration 0003) returns
  // exactly what is needed for one notification id, which is a far narrower
  // grant than the key it replaces.
  const admin = createAdminClient();

  const { data: rows, error: lookupError } = await admin.rpc<PushTarget[]>(
    "push_dispatch_payload",
    { p_notification_id: notificationId },
  );

  if (lookupError) {
    return NextResponse.json({ error: "lookup failed" }, { status: 500 });
  }
  if (!rows?.length) {
    // An unknown id, an already-deleted notification, or a recipient who has
    // been deactivated. Nothing to do and no reason to retry.
    return NextResponse.json({ ok: true, sent: 0, reason: "not found" });
  }

  const notification = rows[0];
  // A left join, so a recipient with no registered device produces one row
  // with a null subscription. That is the ordinary case for anyone who has
  // not turned notifications on, not a failure — the bell already has it.
  const subscriptions = rows
    .filter((r) => r.subscription_id && r.endpoint && r.p256dh && r.auth_secret)
    .map((r) => ({
      id: r.subscription_id as string,
      endpoint: r.endpoint as string,
      p256dh: r.p256dh as string,
      auth: r.auth_secret as string,
    }));

  if (!subscriptions.length) {
    return NextResponse.json({ ok: true, sent: 0, reason: "no devices" });
  }

  webpush.setVapidDetails(subject, publicKey, privateKey);

  const role = (notification.recipient_role ?? "driver") as UserRole;
  const url = notification.order_id
    ? `${ORDER_DETAIL_BASE[role]}/${notification.order_id}`
    : `/${role}`;

  const payload = JSON.stringify({
    title: notification.title,
    body: notification.body ?? "",
    url,
    // One live notification per order per device: a second message on an
    // order replaces the first rather than stacking up a column of them.
    tag: notification.order_id ? `order-${notification.order_id}` : notification.notification_type,
    // A new order is the one thing a driver must not scroll past, so it
    // stays on screen until they acknowledge it. Chat does not — messages
    // arrive often enough that a sticky notification each time would be an
    // irritation rather than a help.
    requireInteraction: notification.notification_type === "order_assigned",
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

  // Through functions for the same reason as the read: with no identity,
  // push_subscriptions_delete_own matches nothing, so a direct delete would
  // silently remove zero dead endpoints and they would be retried forever.
  if (gone.length) {
    await admin.rpc("push_prune_subscriptions", { p_ids: gone });
  }
  if (delivered.length) {
    await admin.rpc("push_mark_delivered", { p_ids: delivered });
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
