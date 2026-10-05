import { timingSafeEqual } from "node:crypto";
import { NextResponse } from "next/server";
import { sendPushForNotification, pushIsConfigured } from "@/lib/push/send";
import { drainPushOutbox } from "@/lib/push/outbox";

export const runtime = "nodejs";

function secretMatches(provided: string | null, expected: string): boolean {
  if (!provided) return false;
  const a = Buffer.from(provided);
  const b = Buffer.from(expected);
  if (a.length !== b.length) return false;
  return timingSafeEqual(a, b);
}

/**
 * Sends one notification, named in the body, or drains whatever is queued.
 *
 * This endpoint exists because on Supabase the database itself called it,
 * through pg_net. On Neon the database cannot make an HTTP request at all,
 * so the queued request is drained in-process instead — see
 * src/lib/push/outbox.ts. The endpoint is kept for two reasons: a body with
 * a notification_id still works, which is what the trigger queues and what
 * a pg_net-capable database would still send; and POSTing with no
 * notification_id now drains the backlog, which is a way to flush the queue
 * by hand, or from a scheduler if one is ever wanted.
 *
 * Either way it needs the shared secret.
 */
export async function POST(request: Request) {
  const secret = process.env.PUSH_WEBHOOK_SECRET;
  if (!secret || !pushIsConfigured()) {
    return NextResponse.json({ error: "push not configured" }, { status: 503 });
  }
  if (!secretMatches(request.headers.get("x-push-secret"), secret)) {
    return NextResponse.json({ error: "unauthorized" }, { status: 401 });
  }

  let notificationId: string | undefined;
  try {
    const body = (await request.json()) as { notification_id?: string };
    notificationId = body.notification_id;
  } catch {
    // An empty or unparseable body means "drain the queue".
  }

  if (!notificationId) {
    const drained = await drainPushOutbox(100);
    return NextResponse.json({ ok: true, drained: true, ...drained });
  }

  try {
    const outcome = await sendPushForNotification(notificationId);
    return NextResponse.json({
      ok: true,
      sent: outcome.sent,
      removed: outcome.removed,
      failed: outcome.failed,
      ...(outcome.reason ? { reason: outcome.reason } : {}),
      ...(outcome.errors.length ? { errors: outcome.errors } : {}),
    });
  } catch {
    return NextResponse.json({ error: "lookup failed" }, { status: 500 });
  }
}
