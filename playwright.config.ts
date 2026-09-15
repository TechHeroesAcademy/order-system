import { defineConfig, devices } from "@playwright/test";
import { existsSync } from "node:fs";

const SANDBOX_CHROME = "/opt/pw-browsers/chromium-1194/chrome-linux/chrome";

/**
 * End-to-end tests against a real running instance of the app.
 *
 * Two layers are covered here deliberately differently:
 *  - Public, unauthenticated pages (homepage, /order/new, /track, /login,
 *    /setup) are real browser tests and run against ANY running instance,
 *    including one wired to a placeholder Supabase project — they verify
 *    the page renders, client-side validation works, and the UI reacts
 *    correctly to a "no such order" response.
 *  - Authenticated, role-gated flows (Owner/Moderator/Driver/Factory
 *    dashboards, the full order lifecycle) need a real Supabase project
 *    with seeded accounts (see supabase/seed.sql) to sign in against, so
 *    they're written here and skip themselves with a clear message when
 *    E2E_BASE_URL/E2E_STAFF_PASSWORD aren't pointed at one — see
 *    e2e/README.md for how to run the full suite against a staging
 *    project.
 */
export default defineConfig({
  testDir: "./e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: [["list"]],
  use: {
    baseURL: process.env.E2E_BASE_URL ?? "http://127.0.0.1:3100",
    trace: "on-first-retry",
    screenshot: "only-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: {
        ...devices["Desktop Chrome"],
        // This sandbox pins a pre-installed Chromium build that doesn't
        // match whatever version @playwright/test's default headless-shell
        // lookup expects — point at it explicitly instead of downloading
        // a new one. Safe to leave in place outside this sandbox too:
        // launch() falls back to its own bundled browser wherever this
        // exact path doesn't exist.
        launchOptions: existsSync(SANDBOX_CHROME) ? { executablePath: SANDBOX_CHROME } : {},
      },
    },
  ],
  webServer: process.env.E2E_BASE_URL
    ? undefined
    : {
        command: "npm run build && npm run start -- -p 3100",
        url: "http://127.0.0.1:3100",
        reuseExistingServer: !process.env.CI,
        timeout: 180_000,
      },
});
