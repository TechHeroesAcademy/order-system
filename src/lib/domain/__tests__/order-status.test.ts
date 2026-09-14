import { describe, expect, it } from "vitest";
import {
  isOrderDelayed,
  isTerminalStatus,
  ORDER_SLA_HOURS,
  ORDER_STATUS_LABELS_AR,
  ORDER_STATUS_SEQUENCE,
  statusProgressPercent,
  TERMINAL_STATUSES,
  eventTypeLabel,
} from "@/lib/domain/order-status";
import type { OrderStatus } from "@/types/database";

describe("order status metadata", () => {
  it("has an Arabic label for every status", () => {
    const allStatuses: OrderStatus[] = [
      ...ORDER_STATUS_SEQUENCE,
      "refused",
      "cancelled",
    ];
    for (const status of allStatuses) {
      expect(ORDER_STATUS_LABELS_AR[status]).toBeTruthy();
    }
  });

  it("treats delivered/refused/cancelled as terminal, nothing else", () => {
    expect(TERMINAL_STATUSES).toEqual(["delivered", "refused", "cancelled"]);
    for (const status of ORDER_STATUS_SEQUENCE) {
      if (status !== "delivered") {
        expect(isTerminalStatus(status)).toBe(false);
      }
    }
    expect(isTerminalStatus("delivered")).toBe(true);
    expect(isTerminalStatus("refused")).toBe(true);
    expect(isTerminalStatus("cancelled")).toBe(true);
  });

  it("progresses monotonically along the main sequence", () => {
    const percents = ORDER_STATUS_SEQUENCE.map(statusProgressPercent);
    for (let i = 1; i < percents.length; i++) {
      expect(percents[i]).toBeGreaterThan(percents[i - 1]);
    }
    expect(percents[0]).toBe(0);
    expect(percents[percents.length - 1]).toBe(100);
  });

  it("side-exit statuses are considered fully progressed", () => {
    expect(statusProgressPercent("refused")).toBe(100);
    expect(statusProgressPercent("cancelled")).toBe(100);
  });
});

describe("isOrderDelayed", () => {
  const now = new Date("2026-01-10T12:00:00Z");

  it("is not delayed just under the SLA", () => {
    const createdAt = new Date(now.getTime() - (ORDER_SLA_HOURS - 1) * 3600_000).toISOString();
    expect(isOrderDelayed("assigned", createdAt, now)).toBe(false);
  });

  it("is delayed just over the SLA", () => {
    const createdAt = new Date(now.getTime() - (ORDER_SLA_HOURS + 1) * 3600_000).toISOString();
    expect(isOrderDelayed("assigned", createdAt, now)).toBe(true);
  });

  it("never flags a terminal order as delayed, no matter how old", () => {
    const createdAt = new Date(now.getTime() - 30 * 24 * 3600_000).toISOString();
    expect(isOrderDelayed("delivered", createdAt, now)).toBe(false);
    expect(isOrderDelayed("refused", createdAt, now)).toBe(false);
    expect(isOrderDelayed("cancelled", createdAt, now)).toBe(false);
  });
});

describe("eventTypeLabel", () => {
  it("returns a known Arabic label", () => {
    expect(eventTypeLabel("delivered")).toBe("تم التسليم للعميل");
  });

  it("falls back to the raw value for unknown events", () => {
    expect(eventTypeLabel("some_future_event")).toBe("some_future_event");
  });
});
