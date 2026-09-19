import { describe, it, expect } from "vitest";
import { groupOrdersByRegion } from "../distribution";
import type { OrderListRow } from "@/lib/data/orders";

function order(id: string, regionId: string | null, regionName: string | null): OrderListRow {
  return {
    id,
    region_id: regionId,
    region: regionName ? { name: regionName } : null,
  } as OrderListRow;
}

describe("groupOrdersByRegion", () => {
  it("groups orders by area, keeping each area's orders together", () => {
    const groups = groupOrdersByRegion([
      order("1", "r-shubra", "شبرا"),
      order("2", "r-october", "أكتوبر"),
      order("3", "r-shubra", "شبرا"),
    ]);

    expect(groups).toHaveLength(2);
    const shubra = groups.find((g) => g.regionId === "r-shubra");
    expect(shubra?.orders.map((o) => o.id)).toEqual(["1", "3"]);
    expect(groups.find((g) => g.regionId === "r-october")?.orders).toHaveLength(1);
  });

  it("preserves the order rows were given in within a group", () => {
    const groups = groupOrdersByRegion([
      order("c", "r", "شبرا"),
      order("a", "r", "شبرا"),
      order("b", "r", "شبرا"),
    ]);
    expect(groups[0].orders.map((o) => o.id)).toEqual(["c", "a", "b"]);
  });

  it("puts orders with no area in their own bucket, always last", () => {
    const groups = groupOrdersByRegion([
      order("1", null, null),
      order("2", "r-shubra", "شبرا"),
    ]);

    expect(groups).toHaveLength(2);
    expect(groups[groups.length - 1].regionId).toBeNull();
    expect(groups[groups.length - 1].regionName).toBe("بدون منطقة");
  });

  it("returns nothing for an empty list rather than an empty group", () => {
    expect(groupOrdersByRegion([])).toEqual([]);
  });

  it("treats two orders naming the same area as one group", () => {
    // Areas are canonical rows (find_or_create_region), so the same typed
    // name always resolves to one id — grouping keys on the id, not the text.
    const groups = groupOrdersByRegion([
      order("1", "r-shubra", "شبرا"),
      order("2", "r-shubra", "شبرا"),
    ]);
    expect(groups).toHaveLength(1);
    expect(groups[0].orders).toHaveLength(2);
  });
});
