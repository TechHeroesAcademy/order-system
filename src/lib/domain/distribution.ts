import type { OrderListRow } from "@/lib/data/orders";

export interface RegionGroup {
  regionId: string | null;
  regionName: string;
  orders: OrderListRow[];
}

/**
 * Groups orders by area for the board. Done here rather than in SQL: these
 * are page-sized lists, and keeping it in JS avoids a grouping RPC and keeps
 * the row type unchanged.
 */
export function groupOrdersByRegion(orders: OrderListRow[]): RegionGroup[] {
  const groups = new Map<string, RegionGroup>();

  for (const order of orders) {
    const regionName = order.region?.name ?? "بدون منطقة";
    const key = order.region_id ?? "__none__";
    const existing = groups.get(key);
    if (existing) {
      existing.orders.push(order);
    } else {
      groups.set(key, { regionId: order.region_id, regionName, orders: [order] });
    }
  }

  // Alphabetical by area, with the unassigned-area bucket last so it never
  // pushes a real area off the top of the screen.
  return [...groups.values()].sort((a, b) => {
    if (a.regionId === null) return 1;
    if (b.regionId === null) return -1;
    return a.regionName.localeCompare(b.regionName, "ar");
  });
}
