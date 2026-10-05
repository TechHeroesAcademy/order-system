import type { OrderListRow } from "@/lib/data/orders";

export interface RegionGroup {
  regionId: string | null;
  regionName: string;
  orders: OrderListRow[];
}

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

  return [...groups.values()].sort((a, b) => {
    if (a.regionId === null) return 1;
    if (b.regionId === null) return -1;
    return a.regionName.localeCompare(b.regionName, "ar");
  });
}
