import { describe, it, expect } from "vitest";
import { navItemsForRole } from "../nav-items";

/**
 * This menu has now broken twice in two different ways, so it gets tests.
 *
 * First: five items overflowed a 375px phone and silently pushed التقارير
 * and الفريق off the edge. Second: التوزيع lives under /moderator, so
 * Next.js rendered a Manager with the moderator layout and its menu, which
 * has no التقارير — reports vanished on opening distribution and reappeared
 * on navigating away.
 *
 * Both failures look identical to the person using it: "the reports page is
 * gone". The assertions below are about what a Manager can always reach.
 */

const labels = (role: Parameters<typeof navItemsForRole>[0]) =>
  navItemsForRole(role).map((i) => i.label);

describe("navItemsForRole", () => {
  it("gives a Manager every screen they own", () => {
    expect(labels("owner")).toEqual(["الرئيسية", "الأوردرات", "التوزيع", "التقارير", "الفريق"]);
  });

  it("keeps التقارير in a Manager's menu even though التوزيع lives under /moderator", () => {
    // The regression. The distribution board's URL is in the moderator tree;
    // the menu must not change because of that.
    const owner = navItemsForRole("owner");
    expect(owner.find((i) => i.label === "التوزيع")?.href).toBe("/moderator/distribution");
    expect(owner.map((i) => i.label)).toContain("التقارير");
  });

  it("points a Manager's own screens at /owner, not the moderator copies", () => {
    const byLabel = Object.fromEntries(navItemsForRole("owner").map((i) => [i.label, i.href]));
    expect(byLabel["الرئيسية"]).toBe("/owner");
    expect(byLabel["الأوردرات"]).toBe("/owner/orders");
    expect(byLabel["التقارير"]).toBe("/owner/reports");
    expect(byLabel["الفريق"]).toBe("/owner/team");
  });

  it("does not offer a Moderator screens that are Manager-only", () => {
    const moderator = labels("moderator");
    expect(moderator).not.toContain("التقارير");
    expect(moderator).not.toContain("الفريق");
  });

  it("gives a Moderator their own working set", () => {
    expect(labels("moderator")).toEqual(["الرئيسية", "الأوردرات", "التوزيع", "أوردر جديد"]);
  });

  it("keeps every menu to five items or fewer", () => {
    // The width fix (wrapping, icons hidden below sm) was measured at five.
    // A sixth would not be hidden any more — it wraps — but it would eat
    // another row of a phone screen, so this is a prompt to check rather
    // than a hard rule.
    for (const role of ["owner", "moderator"] as const) {
      expect(navItemsForRole(role).length).toBeLessThanOrEqual(5);
    }
  });

  it("never emits a duplicate destination", () => {
    for (const role of ["owner", "moderator"] as const) {
      const hrefs = navItemsForRole(role).map((i) => i.href);
      expect(new Set(hrefs).size).toBe(hrefs.length);
    }
  });
});
