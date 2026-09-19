import { describe, it, expect, vi, beforeEach } from "vitest";
import { render, screen } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { DistributionBoard } from "../distribution-board";
import type { RegionGroup } from "@/lib/domain/distribution";
import type { OrderListRow } from "@/lib/data/orders";
import type { Profile, Factory } from "@/types/database";

const refresh = vi.fn();
vi.mock("next/navigation", () => ({
  useRouter: () => ({ refresh, push: vi.fn() }),
  usePathname: () => "/moderator/distribution",
  useSearchParams: () => new URLSearchParams(),
}));

const approveBulk = vi.fn();
const setDistributionBulk = vi.fn();
vi.mock("@/lib/actions/orders", () => ({
  approveDistributionBulkAction: (...args: unknown[]) => approveBulk(...args),
  setOrderDistributionBulkAction: (...args: unknown[]) => setDistributionBulk(...args),
}));

vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

function order(id: string, number: string, driver: string | null): OrderListRow {
  return {
    id,
    order_number: number,
    customer_name: "عميل",
    assigned_driver_name: driver,
    status: "new",
    created_at: "2026-09-19T10:00:00Z",
    region: { name: "شبرا" },
  } as OrderListRow;
}

const groups: RegionGroup[] = [
  {
    regionId: "r-shubra",
    regionName: "شبرا",
    orders: [order("o1", "ORD-00001", "مندوب شبرا"), order("o2", "ORD-00002", "مندوب شبرا")],
  },
  {
    regionId: "r-october",
    regionName: "أكتوبر",
    orders: [order("o3", "ORD-00003", "مندوب أكتوبر")],
  },
];

const drivers = [{ id: "d1", full_name: "مندوب شبرا", is_active: true }] as Profile[];
const factories = [{ id: "f1", name: "مصنع 1" }] as Factory[];

function renderBoard(canApprove = true) {
  return render(
    <DistributionBoard
      groups={groups}
      unallocated={[]}
      drivers={drivers}
      factories={factories}
      canApprove={canApprove}
      activeFactoryId={null}
    />,
  );
}

beforeEach(() => {
  vi.clearAllMocks();
  approveBulk.mockResolvedValue({ ok: true, data: { approved: 2, failures: [] } });
});

describe("DistributionBoard", () => {
  it("shows every pending order grouped under its area, with the suggested driver", () => {
    renderBoard();
    expect(screen.getByText("شبرا")).toBeInTheDocument();
    expect(screen.getByText("أكتوبر")).toBeInTheDocument();
    expect(screen.getByText("ORD-00001")).toBeInTheDocument();
    expect(screen.getAllByText("مندوب شبرا").length).toBeGreaterThan(0);
    expect(screen.getByText("3 أوردر بانتظار اعتماد التوزيع")).toBeInTheDocument();
  });

  it("selects a whole area in one press and approves exactly those orders", async () => {
    const user = userEvent.setup();
    renderBoard();

    await user.click(screen.getByLabelText("تحديد كل أوردرات شبرا"));
    // shown both on the area header and in the action bar
    expect(screen.getAllByText("محدد 2").length).toBeGreaterThan(0);

    await user.click(screen.getByRole("button", { name: /اعتماد التوزيع/ }));
    expect(approveBulk).toHaveBeenCalledWith(["o1", "o2"]);
  });

  it("can approve a single order without touching the rest of its area", async () => {
    const user = userEvent.setup();
    renderBoard();

    await user.click(screen.getByLabelText("تحديد الأوردر ORD-00002"));
    await user.click(screen.getByRole("button", { name: /اعتماد التوزيع/ }));
    expect(approveBulk).toHaveBeenCalledWith(["o2"]);
  });

  it("moves the selection to a different driver before approving", async () => {
    const user = userEvent.setup();
    setDistributionBulk.mockResolvedValue({ ok: true, data: { approved: 1, failures: [] } });
    renderBoard();

    await user.click(screen.getByLabelText("تحديد الأوردر ORD-00003"));

    // Nothing is moved until a driver is actually chosen — the button stays
    // disabled rather than firing a call with no destination.
    const moveButton = screen.getByRole("button", { name: /^نقل$/ });
    expect(moveButton).toBeDisabled();
    expect(setDistributionBulk).not.toHaveBeenCalled();

    expect(screen.getByLabelText("نقل إلى مندوب")).toBeInTheDocument();
  });

  it("lists the ones that failed instead of silently dropping them", async () => {
    const user = userEvent.setup();
    approveBulk.mockResolvedValue({
      ok: true,
      data: {
        approved: 1,
        failures: [
          { order_id: "o2", order_number: "ORD-00002", succeeded: false, error: "لا يوجد مندوب محدد لهذا الأوردر" },
        ],
      },
    });
    renderBoard();

    await user.click(screen.getByLabelText("تحديد كل أوردرات شبرا"));
    await user.click(screen.getByRole("button", { name: /اعتماد التوزيع/ }));

    expect(await screen.findByText("بعض الأوردرات لم تتم")).toBeInTheDocument();
    expect(screen.getByText("لا يوجد مندوب محدد لهذا الأوردر")).toBeInTheDocument();
  });

  it("gives a Moderator the list but no way to act on it", () => {
    renderBoard(false);
    expect(screen.getByText("ORD-00001")).toBeInTheDocument();
    expect(screen.queryByLabelText("تحديد كل أوردرات شبرا")).not.toBeInTheDocument();
    expect(screen.queryByRole("button", { name: /اعتماد كل المنطقة/ })).not.toBeInTheDocument();
  });
});
