import { describe, it, expect, vi, beforeEach, afterEach } from "vitest";
import { render, screen, act } from "@testing-library/react";
import { OrderChat } from "../order-chat";
import type { OrderMessage } from "@/types/database";

const listMessages = vi.fn();
const sendMessage = vi.fn();
vi.mock("@/lib/actions/orders", () => ({
  listOrderMessagesAction: (...a: unknown[]) => listMessages(...a),
  sendOrderMessageAction: (...a: unknown[]) => sendMessage(...a),
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

function msg(id: string, body = "مرحبا"): OrderMessage {
  return {
    id,
    order_id: "o1",
    channel: "driver",
    sender_id: "u1",
    sender_role: "driver",
    body,
    created_at: "2026-09-19T10:00:00Z",
  } as OrderMessage;
}

async function advance(ms: number) {
  await act(async () => {
    vi.advanceTimersByTime(ms);
    await Promise.resolve();
    await Promise.resolve();
  });
}

beforeEach(() => {
  vi.useFakeTimers();
  vi.clearAllMocks();
  listMessages.mockResolvedValue({ ok: true, data: [msg("m1")] });
});
afterEach(() => {
  vi.useRealTimers();
});

describe("OrderChat polling", () => {
  it("loads the thread immediately on mount", async () => {
    await act(async () => {
      render(<OrderChat orderId="o1" channel="driver" viewerId="u1" />);
    });
    expect(listMessages).toHaveBeenCalledTimes(1);
    expect(listMessages).toHaveBeenCalledWith("o1", "driver");
    expect(screen.getByText("مرحبا")).toBeInTheDocument();
  });

  it("keeps checking while the thread is active", async () => {
    await act(async () => {
      render(<OrderChat orderId="o1" channel="driver" viewerId="u1" />);
    });
    const afterMount = listMessages.mock.calls.length;

    listMessages.mockResolvedValueOnce({ ok: true, data: [msg("m1"), msg("m2")] });
    await advance(4000);
    expect(listMessages.mock.calls.length).toBeGreaterThan(afterMount);
  });

  it("backs off when nothing is happening, instead of polling forever at 4s", async () => {
    await act(async () => {
      render(<OrderChat orderId="o1" channel="driver" viewerId="u1" />);
    });

    for (let i = 0; i < 15; i++) await advance(4000);

    const calls = listMessages.mock.calls.length;
    expect(calls).toBeLessThan(12);
    expect(calls).toBeGreaterThan(2);
  });

  it("still checks eventually after a long idle stretch, just rarely", async () => {
    await act(async () => {
      render(<OrderChat orderId="o1" channel="driver" viewerId="u1" />);
    });
    for (let i = 0; i < 10; i++) await advance(30000);
    const before = listMessages.mock.calls.length;
    await advance(420000);
    expect(listMessages.mock.calls.length).toBeGreaterThan(before);
  });

  it("STOPS ENTIRELY while the tab is hidden, so the database can sleep", async () => {
    // Neon suspends its compute after five minutes with no query, and
    // billing is by the hour the compute is awake. The old behaviour polled
    // every 60s while hidden, which meant one order page left open on one
    // phone kept the database awake 24 hours a day.
    await act(async () => {
      render(<OrderChat orderId="o1" channel="driver" viewerId="u1" />);
    });

    Object.defineProperty(document, "hidden", { value: true, configurable: true });
    document.dispatchEvent(new Event("visibilitychange"));

    const before = listMessages.mock.calls.length;
    for (let i = 0; i < 20; i++) await advance(60000);
    expect(listMessages.mock.calls.length).toBe(before);

    Object.defineProperty(document, "hidden", { value: false, configurable: true });
    await act(async () => {
      document.dispatchEvent(new Event("visibilitychange"));
    });
    expect(listMessages.mock.calls.length).toBeGreaterThan(before);
  });

  it("stops polling once unmounted", async () => {
    let view: ReturnType<typeof render> | undefined;
    await act(async () => {
      view = render(<OrderChat orderId="o1" channel="driver" viewerId="u1" />);
    });
    view!.unmount();
    const after = listMessages.mock.calls.length;
    await advance(60000);
    expect(listMessages.mock.calls.length).toBe(after);
  });
});
