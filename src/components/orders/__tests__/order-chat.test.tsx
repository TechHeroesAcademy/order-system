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

/** Runs pending timers and lets the awaited action promises settle. */
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
    // getByText, not findByText: findBy* polls on real timers, which never
    // advance under vi.useFakeTimers() — it would hang until the test times
    // out. The act() above already flushed the load, so the text is there now.
    expect(screen.getByText("مرحبا")).toBeInTheDocument();
  });

  it("keeps checking while the thread is active", async () => {
    await act(async () => {
      render(<OrderChat orderId="o1" channel="driver" viewerId="u1" />);
    });
    const afterMount = listMessages.mock.calls.length;

    // every new poll returns something different, so the cadence stays fast
    listMessages.mockResolvedValueOnce({ ok: true, data: [msg("m1"), msg("m2")] });
    await advance(4000);
    expect(listMessages.mock.calls.length).toBeGreaterThan(afterMount);
  });

  it("backs off when nothing is happening, instead of polling forever at 4s", async () => {
    await act(async () => {
      render(<OrderChat orderId="o1" channel="driver" viewerId="u1" />);
    });

    // Same thread every time: the cadence should step down the ladder.
    // Walk 60s of wall-clock in 4s slices — a flat 4s poll would fire ~15
    // times; the ladder should fire meaningfully fewer.
    for (let i = 0; i < 15; i++) await advance(4000);

    const calls = listMessages.mock.calls.length;
    expect(calls).toBeLessThan(12);
    // ...but it must NOT stop entirely — that would be a silent breakage.
    expect(calls).toBeGreaterThan(2);
  });

  it("never stops polling, even after a long idle stretch", async () => {
    await act(async () => {
      render(<OrderChat orderId="o1" channel="driver" viewerId="u1" />);
    });
    for (let i = 0; i < 10; i++) await advance(30000);
    const before = listMessages.mock.calls.length;
    await advance(30000);
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
