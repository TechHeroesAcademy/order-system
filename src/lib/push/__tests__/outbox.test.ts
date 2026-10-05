// @vitest-environment node
/**
 * The queued-push drain, against a real database.
 *
 * This is the path that broke notifications on phones after the move off
 * Supabase: the trigger queued an HTTP request into public.push_outbox,
 * because Neon has no pg_net to send it, and nothing drained that table.
 * Nothing errored — queuing worked perfectly — so there was no symptom
 * except silence on every phone.
 *
 * Two things are checked here, and the second is the one that stops a
 * repeat: that the drain works, and that the list of RPCs which trigger a
 * drain still matches what the schema actually does.
 *
 *   DATABASE_URL=... ADMIN_DATABASE_URL=... npx vitest run push/__tests__/outbox
 */

import { describe, it, expect, beforeAll, vi } from "vitest";
import { NOTIFYING_RPCS } from "../notifying-rpcs";

const DB = process.env.DATABASE_URL;
const ADMIN = process.env.ADMIN_DATABASE_URL;
const suite = DB ? describe : describe.skip;

// web-push would try to reach Google and Apple. The drain's job is to pick
// the right rows and record the right outcome; whether a real push lands is
// not something a test can assert.
const sent: string[] = [];
vi.mock("../send", () => ({
  pushIsConfigured: () => true,
  sendPushForNotification: async (id: string) => {
    sent.push(id);
    return { sent: 1, removed: 0, failed: 0, errors: [] };
  },
}));

let ownerId: string;
let DbClientRef: typeof import("@/lib/db/query-builder").DbClient;
vi.mock("@/lib/db/client", async (importOriginal) => {
  const actual = await importOriginal<typeof import("@/lib/db/client")>();
  return {
    ...actual,
    currentProfileId: async () => null,
    createAdminClient: () => new DbClientRef(null),
  };
});

suite("push outbox drain", () => {
  let pg: typeof import("pg").default;
  let admin: import("pg").Client;

  beforeAll(async () => {
    DbClientRef = (await import("@/lib/db/query-builder")).DbClient;
    pg = (await import("pg")).default;
    admin = new pg.Client({ connectionString: ADMIN ?? DB });
    await admin.connect();
    const r = await admin.query(
      "select id from public.profiles where role = 'owner' and is_active limit 1",
    );
    ownerId = r.rows[0]?.id;
    expect(ownerId, "the target database needs an owner").toBeTruthy();
  });

  async function queueOne(): Promise<{ outboxId: number; notificationId: string }> {
    const n = await admin.query(
      `insert into public.notifications (user_id, type, title, body)
       values ($1, 'order_assigned', 'اختبار', 'اختبار')
       returning id`,
      [ownerId],
    );
    const notificationId = n.rows[0].id as string;
    const o = await admin.query(
      `insert into public.push_outbox (url, body, headers)
       values ('https://example.test/api/push/dispatch',
               jsonb_build_object('notification_id', $1::text), '{}'::jsonb)
       returning id`,
      [notificationId],
    );
    return { outboxId: Number(o.rows[0].id), notificationId };
  }

  it("the trigger really does queue a row rather than sending it", async () => {
    // The original bug, stated as a fact about the database: a notification
    // for someone with a registered device leaves a pending outbox row.
    const before = await admin.query(
      "select count(*)::int as n from public.push_outbox where delivered_at is null",
    );
    await admin.query(
      `insert into public.push_subscriptions (user_id, endpoint, p256dh, auth)
       values ($1, 'https://fcm.googleapis.com/fcm/send/TEST-' || gen_random_uuid(), 'x', 'y')`,
      [ownerId],
    );
    await admin.query(
      `insert into public.app_settings (key, value) values
         ('push_endpoint_url', 'https://example.test/api/push/dispatch'),
         ('push_webhook_secret', 'test-secret')
       on conflict (key) do update set value = excluded.value`,
    );
    await admin.query(
      `insert into public.notifications (user_id, type, title, body)
       values ($1, 'order_assigned', 'اختبار الطابور', 'اختبار')`,
      [ownerId],
    );
    const after = await admin.query(
      "select count(*)::int as n from public.push_outbox where delivered_at is null",
    );
    expect(after.rows[0].n).toBeGreaterThan(before.rows[0].n);
  });

  it("claiming counts an attempt, so a stuck row cannot retry for ever", async () => {
    const { outboxId } = await queueOne();
    const first = await admin.query("select * from public.push_outbox_claim(50)");
    const mine = first.rows.find((r) => Number(r.id) === outboxId);
    expect(mine, "the new row should be claimed").toBeTruthy();
    expect(Number(mine.attempts)).toBe(1);

    const second = await admin.query("select * from public.push_outbox_claim(50)");
    expect(Number(second.rows.find((r) => Number(r.id) === outboxId).attempts)).toBe(2);

    await admin.query("update public.push_outbox set attempts = 5 where id = $1", [outboxId]);
    const third = await admin.query("select * from public.push_outbox_claim(50)");
    expect(third.rows.some((r) => Number(r.id) === outboxId)).toBe(false);
  });

  it("drains a pending row and marks it delivered", async () => {
    await admin.query("update public.push_outbox set delivered_at = now() where delivered_at is null");
    const { outboxId, notificationId } = await queueOne();
    sent.length = 0;

    const { drainPushOutbox } = await import("../outbox");
    const result = await drainPushOutbox(10);

    expect(sent).toContain(notificationId);
    expect(result.sent).toBeGreaterThan(0);

    const row = await admin.query("select delivered_at from public.push_outbox where id = $1", [
      outboxId,
    ]);
    expect(row.rows[0].delivered_at).not.toBeNull();
  });

  it("a drain with nothing queued does no work", async () => {
    await admin.query("update public.push_outbox set delivered_at = now() where delivered_at is null");
    const { drainPushOutbox } = await import("../outbox");
    const result = await drainPushOutbox(10);
    expect(result).toEqual({ sent: 0, failed: 0 });
  });

  it("mark_sent does not resurrect an already-delivered row", async () => {
    const { outboxId } = await queueOne();
    await admin.query("select public.push_outbox_mark_sent(array[$1]::bigint[])", [outboxId]);
    const first = await admin.query(
      "select delivered_at from public.push_outbox where id = $1",
      [outboxId],
    );
    const stamp = first.rows[0].delivered_at;
    const again = await admin.query(
      "select public.push_outbox_mark_sent(array[$1]::bigint[]) as n",
      [outboxId],
    );
    expect(Number(again.rows[0].n)).toBe(0);
    const second = await admin.query(
      "select delivered_at from public.push_outbox where id = $1",
      [outboxId],
    );
    expect(second.rows[0].delivered_at).toEqual(stamp);
  });

  it("NOTIFYING_RPCS still matches every notifying function in the schema", async () => {
    // The guard that matters. If someone adds an RPC that notifies and does
    // not add it here, its push is only sent whenever some OTHER notifying
    // action happens to run — late, or never. Re-derive the answer from the
    // database instead of trusting the list.
    const res = await admin.query(`
      with recursive notifiers as (
        select p.oid, p.proname
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.proname in ('notify_user', 'notify_role', 'notify_staff')
        union
        select p.oid, p.proname
          from pg_proc p join pg_namespace n on n.oid = p.pronamespace, notifiers nf
         where n.nspname = 'public'
           and p.oid <> nf.oid
           and p.prosrc ~ ('\\m' || nf.proname || '\\M')
      )
      select distinct proname from notifiers order by 1
    `);
    const fromSchema = res.rows.map((r) => r.proname as string).sort();
    const fromCode = [...NOTIFYING_RPCS].sort();
    expect(fromCode).toEqual(fromSchema);
  });
});
