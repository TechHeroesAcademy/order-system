import type { OrderSource } from "@/types/database";

/**
 * How each order channel is named in the interface.
 *
 * One map, because the label used to be an inline ternary in the order
 * detail page — "website ? … : Messenger" — which silently mislabelled
 * every driver field order as having come from Messenger the moment a third
 * source existed. The database has the same guard in
 * public.order_source_label (migration 0046); this is its client-side twin.
 */
export const ORDER_SOURCE_LABELS_AR: Record<OrderSource, string> = {
  website: "الموقع",
  messenger: "Messenger",
  driver_field: "المندوب في الشارع",
};

export function orderSourceLabel(source: OrderSource): string {
  return ORDER_SOURCE_LABELS_AR[source] ?? source;
}

/** Field orders are the only ones that reach a driver without approval, so they are marked wherever they appear. */
export function isFieldOrder(source: OrderSource): boolean {
  return source === "driver_field";
}
