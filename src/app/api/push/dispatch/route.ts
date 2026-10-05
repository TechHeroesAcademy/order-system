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
