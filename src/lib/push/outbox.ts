import "server-only";
import { after } from "next/server";
import { createAdminClient } from "@/lib/db/client";
import { sendPushForNotification, pushIsConfigured } from "./send";

export async function drainPushOutbox(limit = 20): Promise<{ sent: number; failed: number }> {
  if (!pushIsConfigured()) return { sent: 0, failed: 0 };

  const admin = createAdminClient();
  const { data: claimed, error } = await admin.rpc<
    { id: number; notification_id: string | null; attempts: number }[]
  >("push_outbox_claim", { p_limit: limit });

  if (error) {
    console.error("[push] could not claim outbox rows:", error.message);
    return { sent: 0, failed: 0 };
  }
  if (!claimed?.length) return { sent: 0, failed: 0 };

  const sentIds: number[] = [];
  const failedIds: number[] = [];
  let firstError = "";
  let sent = 0;

  for (const row of claimed) {
    if (!row.notification_id) {
      sentIds.push(row.id);
      continue;
    }
    try {
      const outcome = await sendPushForNotification(row.notification_id);
      if (outcome.reason === "not found" || outcome.reason === "no devices") {
        sentIds.push(row.id);
        continue;
      }
      if (outcome.failed > 0 && outcome.sent === 0) {
        failedIds.push(row.id);
        firstError ||= outcome.errors[0] ?? "send failed";
        continue;
      }
      sentIds.push(row.id);
      sent += outcome.sent;
    } catch (e) {
      failedIds.push(row.id);
      firstError ||= e instanceof Error ? e.message : "send threw";
    }
  }

  if (sentIds.length) {
    await admin.rpc("push_outbox_mark_sent", { p_ids: sentIds });
  }
  if (failedIds.length) {
    await admin.rpc("push_outbox_mark_failed", { p_ids: failedIds, p_error: firstError });
    console.error(`[push] ${failedIds.length} queued push(es) failed: ${firstError}`);
  }

  return { sent, failed: failedIds.length };
}

let scheduled = false;

export function schedulePushDrain(): void {
  if (scheduled) return;
  scheduled = true;
  try {
    after(async () => {
      scheduled = false;
      try {
        await drainPushOutbox();
      } catch (e) {
        console.error("[push] drain failed:", e instanceof Error ? e.message : e);
      }
    });
  } catch {
    scheduled = false;
    void drainPushOutbox().catch(() => {});
  }
}
