import { test, expect, type Page } from "@playwright/test";

/**
 * Full authenticated order lifecycle, one test per role boundary, run
 * against a real Supabase project with seeded staff accounts (see
 * supabase/seed.sql — or your own staging data). These can't run against a
 * placeholder backend since real sign-in requires a real Auth server, so
 * every test in this file requires the env vars below and skips itself
 * with a clear message otherwise:
 *
 *   E2E_BASE_URL           the running app, e.g. https://staging.yourapp.com
 *   E2E_OWNER_PHONE / E2E_OWNER_PASSWORD
 *   E2E_MODERATOR_PHONE / E2E_MODERATOR_PASSWORD
 *   E2E_DRIVER_PHONE / E2E_DRIVER_PASSWORD
 *
 * Run with:
 *   E2E_BASE_URL=https://staging.example.com \
 *   E2E_OWNER_PHONE=01000000001 E2E_OWNER_PASSWORD=... \
 *   E2E_MODERATOR_PHONE=01000000002 E2E_MODERATOR_PASSWORD=... \
 *   E2E_DRIVER_PHONE=01000000003 E2E_DRIVER_PASSWORD=... \
 *   npm run test:e2e -- e2e/staff-lifecycle.spec.ts
 *
 * See e2e/README.md for the full setup.
 */

const creds = {
  owner: { phone: process.env.E2E_OWNER_PHONE, password: process.env.E2E_OWNER_PASSWORD },
  moderator: { phone: process.env.E2E_MODERATOR_PHONE, password: process.env.E2E_MODERATOR_PASSWORD },
  driver: { phone: process.env.E2E_DRIVER_PHONE, password: process.env.E2E_DRIVER_PASSWORD },
};

const haveStaffCreds = Object.values(creds).every((c) => c.phone && c.password);

test.skip(
  !haveStaffCreds,
  "Set E2E_BASE_URL + E2E_{OWNER,MODERATOR,DRIVER}_{PHONE,PASSWORD} to run the authenticated " +
    "lifecycle suite against a real Supabase project. See e2e/README.md.",
);

async function loginAs(page: Page, role: keyof typeof creds) {
  const { phone, password } = creds[role];
  await page.goto("/login");
  await page.getByLabel("رقم الهاتف").fill(phone!);
  await page.getByRole("button", { name: "متابعة" }).click();
  await page.getByLabel("كلمة المرور").fill(password!);
  await page.getByRole("button", { name: "تسجيل الدخول" }).click();
  await expect(page).toHaveURL(new RegExp(`/${role === "moderator" ? "moderator" : role}`));
}

test.describe("full order lifecycle across all four roles", () => {
  test("customer request -> Moderator registers -> Owner distributes -> Driver delivers -> Factory -> back to customer -> closed", async ({
    browser,
  }) => {
    // Each role gets its own browser context (own cookies/session) so this
    // mirrors four different people on four different devices, exactly as
    // it happens in production.
    const modContext = await browser.newContext();
    const ownerContext = await browser.newContext();
    const driverContext = await browser.newContext();

    const mod = await modContext.newPage();
    const owner = await ownerContext.newPage();
    const driver = await driverContext.newPage();

    // 1) Moderator registers an order phoned/messaged in (spec section 2,
    // channel 2).
    await loginAs(mod, "moderator");
    await mod.goto("/moderator/orders/new");
    const uniquePhone = `010${Date.now().toString().slice(-8)}`;
    await mod.getByLabel("اسم العميل").fill("عميل اختبار E2E");
    await mod.getByLabel("رقم الهاتف").fill(uniquePhone);
    await mod.getByLabel("العنوان").fill("عنوان اختبار");
    // Typed by keyboard, not picked from a list, and mandatory as of
    // migration 0025 — no driver covers this made-up name, so the order is
    // left unassigned for the Owner to distribute manually below, same as
    // this test already exercised before this field existed.
    await mod.getByLabel("المنطقة").fill("منطقة اختبار E2E");
    await mod.getByLabel("عدد القطع").fill("2");
    await mod.getByRole("button", { name: /إنشاء الأوردر/ }).click();
    const orderNumberText = await mod.getByText(/ORD-\d+/).first().textContent();
    const orderNumber = orderNumberText?.match(/ORD-\d+/)?.[0];
    expect(orderNumber).toBeTruthy();
    const deliveryCode = await mod.getByText(/^\d{4}$/).first().textContent();
    expect(deliveryCode).toMatch(/^\d{4}$/);

    // 2) Owner distributes to a driver and approves (spec section 5).
    await loginAs(owner, "owner");
    await owner.goto("/owner/orders");
    await owner.getByPlaceholder(/بحث/).fill(orderNumber!);
    await owner.getByText(orderNumber!).click();
    await owner.getByRole("button", { name: "تعيين" }).first().click();
    await owner.getByRole("button", { name: "اعتماد التوزيع" }).click();
    await expect(owner.getByText("بانتظار الاعتماد")).toHaveCount(0);

    // 3) Driver receives from customer, then records the factory steps
    // themselves — there is no factory account to wait on any more
    // (migration 0034), so steps 3 and 4 are one continuous driver flow.
    await loginAs(driver, "driver");
    await driver.goto("/driver");
    await driver.getByText(orderNumber!).click();
    await driver.getByRole("button", { name: "تم الاستلام من العميل" }).click();

    // 4) Driver drops it at the factory and later records that the work is
    // finished (spec sections 10, 11 — same transitions, driver-operated).
    await driver.getByRole("button", { name: "سلّمت الأوردر للمصنع" }).click();
    await driver.getByRole("button", { name: "المصنع خلّص الشغل" }).click();

    // 5) Same driver (spec section 12) picks up from factory and delivers
    // to the customer with the confirmation code (spec section 13).
    await driver.goto("/driver");
    await driver.getByText(orderNumber!).click();
    await driver.getByRole("button", { name: "استلمت من المصنع" }).click();
    await driver.getByLabel("كود التسليم").fill(deliveryCode!);
    await driver.getByRole("button", { name: "تأكيد التسليم" }).click();
    await expect(driver.getByText("تم التسليم للعميل")).toBeVisible();

    // 6) Customer can now track it as delivered, without logging in.
    const customer = await (await browser.newContext()).newPage();
    await customer.goto("/track");
    await customer.getByLabel("رقم الأوردر").fill(orderNumber!);
    await customer.getByLabel("رقم الهاتف").fill(uniquePhone);
    await customer.getByRole("button", { name: "بحث" }).click();
    await expect(customer.getByText("تم التسليم")).toBeVisible();

    for (const ctx of [modContext, ownerContext, driverContext]) await ctx.close();
  });

  // Spec section 13's explicit security requirement — a wrong code must
  // NOT close the order — is covered at the database/RPC layer by
  // scripts/stress-test.mjs (test 3: concurrent wrong-code attempts),
  // which also proves it holds under concurrent load, not just a single
  // attempt. It isn't duplicated here as a browser test since it needs an
  // order already parked in the with_driver state, which the flow above
  // consumes; wire up your own fixture order here if you want browser-level
  // coverage of that specific step too.
});
