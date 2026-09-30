import { describe, it, expect } from "vitest";
import { ORDER_SOURCE_LABELS_AR, orderSourceLabel, isFieldOrder } from "../order-source";
import type { OrderSource } from "@/types/database";

/**
 * This exists because of the bug it prevents. The order detail page used to
 * label the source with `source === "website" ? "الموقع" : "Messenger"`.
 * The moment a third source was added, every driver field order was
 * labelled as having arrived via Messenger — wrong, and sitting at the top
 * of the order's own timeline where a manager would read it as fact.
 *
 * The exhaustiveness check below is what makes a fourth source fail here
 * rather than silently mislabel itself in production.
 */
const ALL_SOURCES: OrderSource[] = ["website", "messenger", "driver_field"];

describe("order source labels", () => {
  it("labels every source, with no fallthrough", () => {
    for (const source of ALL_SOURCES) {
      const label = orderSourceLabel(source);
      expect(label).toBeTruthy();
      // A label identical to the raw enum value means it fell through to
      // the default and was never actually translated.
      expect(label).not.toBe(source);
    }
  });

  it("has an entry for every source in the union", () => {
    expect(Object.keys(ORDER_SOURCE_LABELS_AR).sort()).toEqual([...ALL_SOURCES].sort());
  });

  it("gives each source a distinct label", () => {
    const labels = ALL_SOURCES.map(orderSourceLabel);
    expect(new Set(labels).size).toBe(labels.length);
  });

  it("does not describe a field order as Messenger — the original bug", () => {
    expect(orderSourceLabel("driver_field")).not.toBe(ORDER_SOURCE_LABELS_AR.messenger);
  });

  it("identifies only driver_field as a field order", () => {
    expect(isFieldOrder("driver_field")).toBe(true);
    expect(isFieldOrder("website")).toBe(false);
    expect(isFieldOrder("messenger")).toBe(false);
  });
});
