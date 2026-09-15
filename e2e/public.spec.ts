import { test, expect } from "@playwright/test";

/**
 * Public, unauthenticated pages — the customer-facing surface of the app
 * (section 15's tracking page) plus the staff login screen. Order creation
 * used to be open to anonymous customers too (spec section 2's "Website"
 * channel via /order/new), but that was later replaced by a product
 * decision: every order now goes through a signed-in team member instead
 * (/moderator/orders/new). /order/new is kept as a redirect rather than
 * deleted, so an old bookmark/link still lands somewhere useful — see
 * src/app/order/new/page.tsx.
 *
 * Two of these are regression tests for real bugs this suite caught:
 *  - "/order/new sends an anonymous visitor to sign in, not the old public
 *    form" — this is the *current* intended behavior (the opposite of an
 *    earlier version of this test, back when anonymous order creation was
 *    still the design).
 *  - "login form is present in the server-rendered HTML, not just after
 *    client hydration" — /login was bailing out to client-side-only
 *    rendering (a Next.js quirk with useSearchParams on a statically
 *    rendered page) and shipping a blank page on first paint.
 */

test.describe("homepage", () => {
  test("renders the tracking entry point and the staff sign-in entry point", async ({ page }) => {
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "شركة المجد" })).toBeVisible();
    await expect(page.getByRole("link", { name: "تتبع الأوردر" })).toBeVisible();
    await expect(page.getByRole("link", { name: "تسجيل الدخول" })).toBeVisible();
    // Order creation is not a public action anymore — no standalone
    // "إنشاء أوردر" entry point on the homepage.
    await expect(page.getByRole("link", { name: "إنشاء أوردر", exact: true })).toHaveCount(0);
  });

  test("the tracking entry point navigates to /track", async ({ page }) => {
    await page.goto("/");
    await page.getByRole("link", { name: "تتبع الأوردر" }).click();
    await expect(page).toHaveURL(/\/track$/);
  });

  test("the sign-in entry point navigates to /login", async ({ page }) => {
    await page.goto("/");
    await page.getByRole("link", { name: "تسجيل الدخول" }).click();
    await expect(page).toHaveURL(/\/login$/);
  });
});

test.describe("/order/new (retired public form)", () => {
  test("sends an anonymous visitor to sign in, pointed at the real order form", async ({ page }) => {
    await page.goto("/order/new");
    await expect(page).toHaveURL(/\/login\?next=%2Fmoderator%2Forders%2Fnew/);
  });
});

test.describe("order tracking (/track)", () => {
  test("prompts for order number and phone", async ({ page }) => {
    await page.goto("/track");
    await expect(page.getByLabel("رقم الأوردر")).toBeVisible();
    await expect(page.getByLabel("رقم الهاتف")).toBeVisible();
  });

  test("rejects a search with no order number", async ({ page }) => {
    await page.goto("/track");
    await page.getByLabel("رقم الهاتف").fill("01012345678");
    await page.getByRole("button", { name: "بحث" }).click();
    // exact:true to avoid also matching the card's longer description text,
    // which contains this string as a substring.
    await expect(page.getByText("أدخل رقم الأوردر", { exact: true })).toBeVisible();
  });
});

test.describe("staff login (/login)", () => {
  test("ships the phone-login form in the initial server-rendered HTML", async ({ request }) => {
    // Regression test for the SSR bailout: fetch the raw HTML directly
    // (no JS execution) and confirm the form is already there, not an
    // empty shell waiting for hydration. Relative path so Playwright
    // resolves it against baseURL itself.
    const res = await request.get("/login");
    const body = await res.text();
    expect(body).not.toContain("BAILOUT_TO_CLIENT_SIDE_RENDERING");
    expect(body).toContain("رقم الهاتف");
  });

  test("shows only the phone-number flow — no email/password form anywhere", async ({ page }) => {
    await page.goto("/login");
    await expect(page.getByLabel("رقم الهاتف")).toBeVisible();
    await expect(page.getByLabel("البريد الإلكتروني")).toHaveCount(0);
    await expect(page.getByPlaceholder("name@example.com")).toHaveCount(0);
  });

  test("rejects a too-short phone number client-side", async ({ page }) => {
    await page.goto("/login");
    await page.getByLabel("رقم الهاتف").fill("123");
    await page.getByRole("button", { name: "متابعة" }).click();
    await expect(page.getByText("رقم الهاتف غير صالح")).toBeVisible();
  });
});

test.describe("role-gated dashboards redirect anonymous visitors to /login", () => {
  for (const path of ["/owner", "/moderator", "/driver", "/factory"]) {
    test(`${path} redirects with a return-to next param`, async ({ page }) => {
      await page.goto(path);
      await expect(page).toHaveURL(new RegExp(`/login\\?next=${encodeURIComponent(path).replace(/\//g, "%2F")}`));
    });
  }
});
