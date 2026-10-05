import { describe, it, expect } from "vitest";
import { ORDER_SOURCE_LABELS_AR, orderSourceLabel, isFieldOrder } from "../order-source";
import type { OrderSource } from "@/types/database";

const ALL_SOURCES: OrderSource[] = ["website", "messenger", "driver_field"];

describe("order source labels", () => {
  it("labels every source, with no fallthrough", () => {
    for (const source of ALL_SOURCES) {
      const label = orderSourceLabel(source);
      expect(label).toBeTruthy();
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
