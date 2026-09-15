import { test, expect, type APIRequestContext } from "@playwright/test";

/**
 * Public, unauthenticated pages — the customer-facing surface of the spec
 * (section 2's "Website" order channel, section 15's tracking page) plus
 * the staff login screen. Most of this runs against any running instance,
 * even one wired to a placeholder Supabase project — but /order/new does
 * one real data read (the region list) to render its form, so the tests
 * that submit that form check reachability first and skip themselves with
 * a clear message if this instance has no live backend, rather than
 * failing with a confusing timeout.
 *
 * Two of these are regression tests for real bugs this suite caught:
 *  - "customer can reach /order/new without being redirected to staff
 *    login" — was broken (see git history on src/lib/supabase/middleware.ts,
 *    PUBLIC_PATHS) until this suite's first run caught it.
 *  - "login form is present in the server-rendered HTML, not just after
 *    client hydration" — /login was bailing out to client-side-only
 *    rendering (a Next.js quirk with useSearchParams on a statically
 *    rendered page) and shipping a blank page on first paint.
 */

async function isLive(request: APIRequestContext, path: string) {
  const res = await request.get(path).catch(() => null);
  return res !== null && res.status() < 500;
}

test.describe("homepage", () => {
  test("renders the two customer entry points and the staff login link", async ({ page }) => {
    await page.goto("/");
    await expect(page.getByRole("heading", { name: "شركة المجد" })).toBeVisible();
    await expect(page.getByRole("link", { name: "إنشاء أوردر" })).toBeVisible();
    await expect(page.getByRole("link", { name: "تتبع الأوردر" })).toBeVisible();
    await expect(page.getByRole("link", { name: /تسجيل دخول فريق العمل/ })).toBeVisible();
  });

  test("the tracking entry point navigates to /track", async ({ page }) => {
    await page.goto("/");
    await page.getByRole("link", { name: "تتبع الأوردر" }).click();
    await expect(page).toHaveURL(/\/track$/);
  });

  test("the order-creation entry point navigates to /order/new", async ({ page, request }) => {
    test.skip(!(await isLive(request, "/order/new")), "No live backend — see e2e/README.md");
    await page.goto("/");
    await page.getByRole("link", { name: "إنشاء أوردر" }).click();
    await expect(page).toHaveURL(/\/order\/new$/);
  });
});

test.describe("public order creation (/order/new)", () => {
  test("is reachable by an anonymous visitor — not redirected to staff login", async ({ page }) => {
    const response = await page.goto("/order/new");
    // Regression test: this route was missing from the middleware's public
    // path list and silently bounced every visitor to /login?next=... —
    // meaning no customer could ever create an order from the website, the
    // spec's first of only two order-intake channels. This holds even
    // without a live backend, since the redirect happens in middleware
    // before the page (and its data fetch) ever runs.
    expect(page.url()).not.toContain("/login");
    expect(response?.status()).not.toBe(307);
  });

  test("rejects an empty submission with client-side validation, no server round trip", async ({ page, request }) => {
    test.skip(!(await isLive(request, "/order/new")), "No live backend — see e2e/README.md");
    await page.goto("/order/new");
    const submit = page.getByRole("button", { name: "إنشاء الأوردر" });
    await submit.click();
    // react-hook-form + zod should block submission and show field errors
    // without ever calling the server action.
    await expect(page.getByText("الاسم قصير جدًا")).toBeVisible();
  });

  test("rejects an invalid phone number", async ({ page, request }) => {
    test.skip(!(await isLive(request, "/order/new")), "No live backend — see e2e/README.md");
    await page.goto("/order/new");
    await page.getByLabel("اسم العميل").fill("أحمد");
    await page.getByLabel("رقم الهاتف").fill("123");
    await page.getByLabel("العنوان").fill("١٢٣ شارع التجربة");
    await page.getByRole("button", { name: "إنشاء الأوردر" }).click();
    await expect(page.getByText("رقم الهاتف غير صالح")).toBeVisible();
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
