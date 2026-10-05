// @vitest-environment node

import { describe, it, expect, beforeAll } from "vitest";

const DB = process.env.DATABASE_URL;
const ADMIN = process.env.ADMIN_DATABASE_URL;
const suite = DB ? describe : describe.skip;

suite("push targeting", () => {
  let pg: typeof import("pg").default;
  let admin: import("pg").Client;
  let ownerId: string;
  let driverA: string;
  let driverB: string;

  const uniq = () => String(Date.now()).slice(-6) + Math.floor(Math.random() * 900 + 100);

  async function asUser(id: string | null, sql: string, values: unknown[] = []) {
    await admin.query("begin");
    await admin.query("select set_config('app.current_profile_id', $1, true)", [id ?? ""]);
    const r = await admin.query(sql, values);
    await admin.query("commit");
    return r;
  }

  beforeAll(async () => {
    pg = (await import("pg")).default;
    admin = new pg.Client({ connectionString: ADMIN ?? DB });
    await admin.connect();

    const o = await admin.query(
      "select id from public.profiles where role = 'owner' and is_active limit 1",
    );
    ownerId = o.rows[0]?.id;
    expect(ownerId).toBeTruthy();

    const a = await asUser(
      ownerId,
      "select * from public.create_staff_account($1, $2, 'driver', $3)",
      ["سائق أ", "0151" + uniq(), ["شبرا"]],
    );
    driverA = a.rows[0].profile_id;
    const b = await asUser(
      ownerId,
      "select * from public.create_staff_account($1, $2, 'driver', $3)",
      ["سائق ب", "0152" + uniq(), ["أكتوبر"]],
    );
    driverB = b.rows[0].profile_id;
    expect(driverA).toBeTruthy();
    expect(driverB).toBeTruthy();
  });

  async function notify(userId: string, title: string): Promise<string> {
    const r = await admin.query(
      `insert into public.notifications (user_id, type, title, body)
       values ($1, 'order_assigned', $2, 'x') returning id`,
      [userId, title],
    );
    return r.rows[0].id as string;
  }

  async function targets(notificationId: string) {
    const r = await admin.query("select * from public.push_dispatch_payload($1)", [
      notificationId,
    ]);
    return r.rows.filter((x) => x.endpoint).map((x) => x.endpoint as string);
  }

  it("a notification reaches only its own recipient's devices", async () => {
    const epA = "https://fcm.googleapis.com/fcm/send/A-" + uniq();
    const epB = "https://fcm.googleapis.com/fcm/send/B-" + uniq();
    await asUser(driverA, "select public.save_push_subscription($1, 'kA', 'sA', 'ua')", [epA]);
    await asUser(driverB, "select public.save_push_subscription($1, 'kB', 'sB', 'ua')", [epB]);

    expect(await targets(await notify(driverA, "لأ"))).toEqual([epA]);
    expect(await targets(await notify(driverB, "لب"))).toEqual([epB]);
  });

  it("a driver with several devices gets all of theirs and nobody else's", async () => {
    const ep1 = "https://fcm.googleapis.com/fcm/send/M1-" + uniq();
    const ep2 = "https://fcm.googleapis.com/fcm/send/M2-" + uniq();
    await asUser(driverA, "select public.save_push_subscription($1, 'k', 's', 'ua')", [ep1]);
    await asUser(driverA, "select public.save_push_subscription($1, 'k', 's', 'ua')", [ep2]);

    const sent = await targets(await notify(driverA, "عدة أجهزة"));
    expect(sent).toContain(ep1);
    expect(sent).toContain(ep2);
    const bEndpoints = await admin.query(
      "select endpoint from public.push_subscriptions where user_id = $1",
      [driverB],
    );
    for (const row of bEndpoints.rows) expect(sent).not.toContain(row.endpoint);
  });

  it("ONE SHARED PHONE: whoever signed in last owns it, and the other stops receiving", async () => {
    // The reported problem. Driver A turns notifications on, then driver B
    // signs in on the same phone. The browser subscription is the same
    // endpoint, so unless it is re-bound, A keeps receiving on a phone B is
    // holding and B receives nothing.
    const shared = "https://fcm.googleapis.com/fcm/send/SHARED-" + uniq();

    await asUser(driverA, "select public.save_push_subscription($1, 'k', 's', 'phone')", [shared]);
    expect(await targets(await notify(driverA, "لأ"))).toContain(shared);

    // B signs in; the app re-binds the existing browser subscription.
    await asUser(driverB, "select public.save_push_subscription($1, 'k', 's', 'phone')", [shared]);

    expect(await targets(await notify(driverB, "لب"))).toContain(shared);
    expect(await targets(await notify(driverA, "لأ مرة أخرى"))).not.toContain(shared);

    // And the phone is listed once, not once per person.
    const rows = await admin.query(
      "select count(*)::int as n from public.push_subscriptions where endpoint = $1",
      [shared],
    );
    expect(rows.rows[0].n).toBe(1);
  });

  it("signing out releases the phone, so the next notification reaches nothing", async () => {
    const ep = "https://fcm.googleapis.com/fcm/send/OUT-" + uniq();
    await asUser(driverA, "select public.save_push_subscription($1, 'k', 's', 'ua')", [ep]);
    expect(await targets(await notify(driverA, "قبل الخروج"))).toContain(ep);

    await asUser(driverA, "select public.delete_push_subscription($1)", [ep]);
    expect(await targets(await notify(driverA, "بعد الخروج"))).not.toContain(ep);
  });

  it("a driver cannot steal another driver's device by endpoint", async () => {
    const ep = "https://fcm.googleapis.com/fcm/send/OWN-" + uniq();
    await asUser(driverA, "select public.save_push_subscription($1, 'k', 's', 'ua')", [ep]);

    // delete_push_subscription must only remove the caller's own row.
    await asUser(driverB, "select public.delete_push_subscription($1)", [ep]);
    const still = await admin.query(
      "select user_id from public.push_subscriptions where endpoint = $1",
      [ep],
    );
    expect(still.rows[0]?.user_id).toBe(driverA);
  });

  it("a deactivated recipient is not notified at all", async () => {
    const ep = "https://fcm.googleapis.com/fcm/send/OFF-" + uniq();
    await asUser(driverB, "select public.save_push_subscription($1, 'k', 's', 'ua')", [ep]);
    const id = await notify(driverB, "قبل الإيقاف");
    expect(await targets(id)).toContain(ep);

    await admin.query("update public.profiles set is_active = false where id = $1", [driverB]);
    expect(await targets(await notify(driverB, "بعد الإيقاف"))).toEqual([]);
    await admin.query("update public.profiles set is_active = true where id = $1", [driverB]);
  });

  it("an unauthenticated caller cannot register a device", async () => {
    await expect(
      asUser(null, "select public.save_push_subscription($1, 'k', 's', 'ua')", [
        "https://fcm.googleapis.com/fcm/send/ANON-" + uniq(),
      ]),
    ).rejects.toMatchObject({ code: "42501" });
    await admin.query("rollback").catch(() => {});
  });
});
