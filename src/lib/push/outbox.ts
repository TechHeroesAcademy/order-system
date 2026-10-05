import "server-only";
import { after } from "next/server";
import { createAdminClient } from "@/lib/db/client";
import { sendPushForNotification, pushIsConfigured } from "./send";
export { NOTIFYING_RPCS } from "./notifying-rpcs";

/**
 * Drains the queue of push requests the database could not send itself.
 *
 * WHY A QUEUE AT ALL
 *
 * On Supabase the notification trigger called pg_net's net.http_post(),
 * which really did make the HTTP request from inside Postgres. Neon has no
 * pg_net, so net.http_post() is a stand-in that writes the request into
 * public.push_outbox — and for a while nothing read that table, which is
 * exactly how notifications stopped arriving on phones: every one was
 * queued, none was sent, and no error appeared anywhere because queuing
 * succeeded.
 *
 * WHY IT RUNS HERE AND NOT ON A SCHEDULE
 *
 * A cron job would mean a scheduled Vercel invocation every minute whether
 * or not anything is waiting, and on the Hobby plan the finest schedule is
 * daily, which is useless for "an order was just assigned to you". Draining
 * inside the request that created the notification costs no extra
 * invocation and delivers immediately. after() runs it once the response
 * has been sent, so the person pressing the button does not wait for it.
 *
 * Any row left behind — because the process died, or a send failed — is
 * picked up by the next drain. push_outbox_claim counts an attempt per
 * claim and stops at five, so a permanently undeliverable row cannot be
 * retried for ever.
 */
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
      // A queued row with no notification id can never be sent; marking it
      // delivered is what takes it out of the queue for good.
      sentIds.push(row.id);
      continue;
    }
    try {
      const outcome = await sendPushForNotification(row.notification_id);
      if (outcome.reason === "not found" || outcome.reason === "no devices") {
        // Nothing to deliver to. Not a failure to retry — the recipient has
        // no device registered, or the notification is gone.
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

/**
 * Schedules a drain for after the response is sent, at most once per
 * request. Never throws into the caller: a notification that fails to send
 * must not fail the action that caused it — the driver's delivery is
 * recorded either way, and the row stays queued for the next drain.
 */
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
    // after() is only callable inside a request. Outside one (a script, a
    // test) there is nothing to schedule against, so drain inline instead.
    scheduled = false;
    void drainPushOutbox().catch(() => {});
  }
}
