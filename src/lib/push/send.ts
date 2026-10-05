import "server-only";
import webpush from "web-push";
import { createAdminClient } from "@/lib/db/client";
import type { UserRole } from "@/types/database";

export interface PushTarget {
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

export interface SendOutcome {
  sent: number;
  removed: number;
  failed: number;
  errors: string[];
  reason?: "not found" | "no devices" | "not configured";
}

const ORDER_DETAIL_BASE: Record<UserRole, string> = {
  owner: "/owner/orders",
  moderator: "/moderator/orders",
  driver: "/driver/orders",
  factory: "/login",
};

export function pushIsConfigured(): boolean {
  return Boolean(
    process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY &&
      process.env.VAPID_PRIVATE_KEY &&
      process.env.VAPID_SUBJECT,
  );
}

export async function sendPushForNotification(notificationId: string): Promise<SendOutcome> {
  const publicKey = process.env.NEXT_PUBLIC_VAPID_PUBLIC_KEY;
  const privateKey = process.env.VAPID_PRIVATE_KEY;
  const subject = process.env.VAPID_SUBJECT;
  if (!publicKey || !privateKey || !subject) {
    return { sent: 0, removed: 0, failed: 0, errors: [], reason: "not configured" };
  }

  const admin = createAdminClient();

  const { data: rows, error } = await admin.rpc<PushTarget[]>("push_dispatch_payload", {
    p_notification_id: notificationId,
  });
  if (error) throw new Error(error.message);
  if (!rows?.length) {
    return { sent: 0, removed: 0, failed: 0, errors: [], reason: "not found" };
  }

  const notification = rows[0];
  const subscriptions = rows
    .filter((r) => r.subscription_id && r.endpoint && r.p256dh && r.auth_secret)
    .map((r) => ({
      id: r.subscription_id as string,
      endpoint: r.endpoint as string,
      p256dh: r.p256dh as string,
      auth: r.auth_secret as string,
    }));

  if (!subscriptions.length) {
    return { sent: 0, removed: 0, failed: 0, errors: [], reason: "no devices" };
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
    tag: notification.order_id ? `order-${notification.order_id}` : notification.notification_type,
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

  const gone: string[] = [];
  const failed: string[] = [];
  const delivered: string[] = [];
  const errors: string[] = [];

  results.forEach((result, i) => {
    const subscription = subscriptions[i];
    if (result.status === "fulfilled") {
      delivered.push(subscription.id);
      return;
    }
    const reason = result.reason as
      | { statusCode?: number; body?: string; message?: string }
      | undefined;
    const status = reason?.statusCode;
    if (status === 404 || status === 410) {
      gone.push(subscription.id);
      return;
    }
    failed.push(subscription.id);
    const detail = (reason?.body || reason?.message || "unknown").slice(0, 300);
    let host = "unknown";
    try {
      host = new URL(subscription.endpoint).host;
    } catch {
    }
    errors.push(`${host} → ${status ?? "no status"}: ${detail}`);
  });

  if (gone.length) await admin.rpc("push_prune_subscriptions", { p_ids: gone });
  if (delivered.length) await admin.rpc("push_mark_delivered", { p_ids: delivered });
  if (failed.length) await admin.rpc("increment_push_failures", { p_ids: failed });

  return { sent: delivered.length, removed: gone.length, failed: failed.length, errors };
}
