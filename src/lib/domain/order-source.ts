import type { OrderSource } from "@/types/database";

export const ORDER_SOURCE_LABELS_AR: Record<OrderSource, string> = {
  website: "الموقع",
  messenger: "Messenger",
  driver_field: "المندوب في الشارع",
};

export function orderSourceLabel(source: OrderSource): string {
  return ORDER_SOURCE_LABELS_AR[source] ?? source;
}

export function isFieldOrder(source: OrderSource): boolean {
  return source === "driver_field";
}
