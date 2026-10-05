import { describe, it, expect } from "vitest";
import { navItemsForRole } from "../nav-items";

const labels = (role: Parameters<typeof navItemsForRole>[0]) =>
  navItemsForRole(role).map((i) => i.label);

describe("navItemsForRole", () => {
  it("gives a Manager every screen they own", () => {
    expect(labels("owner")).toEqual(["الرئيسية", "الأوردرات", "التوزيع", "التقارير", "الفريق"]);
  });

  it("keeps every Manager destination inside /owner, so no screen switches layout", () => {
    for (const item of navItemsForRole("owner")) {
      expect(item.href.startsWith("/owner")).toBe(true);
    }
  });

  it("points a Manager's own screens at /owner, not the moderator copies", () => {
    const byLabel = Object.fromEntries(navItemsForRole("owner").map((i) => [i.label, i.href]));
    expect(byLabel["الرئيسية"]).toBe("/owner");
    expect(byLabel["التوزيع"]).toBe("/owner/distribution");
    expect(byLabel["الأوردرات"]).toBe("/owner/orders");
    expect(byLabel["التقارير"]).toBe("/owner/reports");
    expect(byLabel["الفريق"]).toBe("/owner/team");
  });

  it("does not offer a Moderator screens that are Manager-only", () => {
    const moderator = labels("moderator");
    expect(moderator).not.toContain("التقارير");
    expect(moderator).not.toContain("الفريق");
    expect(moderator).not.toContain("التوزيع");
  });

  it("gives a Moderator their own working set", () => {
    expect(labels("moderator")).toEqual(["الرئيسية", "الأوردرات", "أوردر جديد"]);
  });

  it("keeps every menu to five items or fewer", () => {
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
