import { describe, it, expect, vi, beforeEach, type Mock } from "vitest";
import { render, screen, waitFor, within } from "@testing-library/react";
import userEvent from "@testing-library/user-event";
import { OrderForm } from "../order-form";
import type { CustomerOrderHistory, NewOrderResult, Region } from "@/types/database";
import type { OrderFormValues } from "@/lib/domain/validators";
import type { ActionResult } from "@/lib/actions/types";

/** The create call OrderForm is handed. Typed so the mock has to match it. */
type CreateOrderAction = (values: OrderFormValues) => Promise<ActionResult<NewOrderResult>>;

const lookup = vi.fn();
vi.mock("@/lib/actions/orders", () => ({
  lookupCustomerHistoryAction: (...a: unknown[]) => lookup(...a),
}));
vi.mock("sonner", () => ({ toast: { success: vi.fn(), error: vi.fn() } }));

const regions: Region[] = [{ id: "r1", name: "المعادي" } as Region];

/**
 * Scoped to the dialog on purpose. The inline line under the phone field and
 * the dialog title deliberately use the same "الأوردر رقم N له" wording, so
 * an unscoped text query matches both and cannot tell "the hint appeared"
 * from "the confirmation appeared" — which is the exact distinction these
 * tests exist to make.
 */
function dialog() {
  return screen.findByRole("alertdialog");
}

const noHistory: CustomerOrderHistory = {
  previous_orders: 0,
  open_orders: 0,
  delivered_orders: 0,
  cancelled_orders: 0,
  refused_orders: 0,
  last_order_number: null,
  last_order_at: null,
  last_order_status: null,
  names_seen: null,
};

const twoPrevious: CustomerOrderHistory = {
  ...noHistory,
  previous_orders: 2,
  delivered_orders: 1,
  open_orders: 1,
  last_order_number: "EL-0042",
  last_order_at: "2026-09-20T10:00:00Z",
  last_order_status: "with_driver",
  names_seen: ["سمير علي"],
};

/**
 * Fills every field the schema requires so submit actually reaches the
 * handler. Validation failing silently is the classic way a test like this
 * passes while proving nothing, so each test also asserts on what happened
 * rather than only on what did not.
 */
async function fillForm(
  user: ReturnType<typeof userEvent.setup>,
  { phone = "01012345678", name = "سمير علي" } = {},
) {
  await user.type(screen.getByLabelText("اسم العميل"), name);
  await user.type(screen.getByLabelText("رقم الهاتف"), phone);
  await user.type(screen.getByLabelText("العنوان"), "شارع 9، المعادي");
  await user.type(
    screen.getByLabelText("رابط موقع العميل على خرائط جوجل"),
    "https://maps.app.goo.gl/abc",
  );
  await user.type(screen.getByLabelText("المنطقة"), "المعادي");
}

let action: Mock<CreateOrderAction>;

beforeEach(() => {
  vi.clearAllMocks();
  action = vi.fn<CreateOrderAction>().mockResolvedValue({
    ok: true,
    data: { order_id: "o1", order_number: "EL-0100", pickup_code: "1111", delivery_code: "2222" },
  });
});

describe("OrderForm — repeat customer confirmation", () => {
  it("creates the order with no interruption for a first-time customer", async () => {
    const user = userEvent.setup();
    lookup.mockResolvedValue({ ok: true, data: noHistory });
    render(<OrderForm regions={regions} action={action} showFactoryField={false} />);

    await fillForm(user);
    await user.click(screen.getByRole("button", { name: "إنشاء الأوردر" }));

    await waitFor(() => expect(action).toHaveBeenCalledTimes(1));
    expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument();
  });

  /** The core of the feature: the order must not exist until it is confirmed. */
  it("asks before creating anything when the number has ordered before", async () => {
    const user = userEvent.setup();
    lookup.mockResolvedValue({ ok: true, data: twoPrevious });
    render(<OrderForm regions={regions} action={action} showFactoryField={false} />);

    await fillForm(user);
    await user.click(screen.getByRole("button", { name: "إنشاء الأوردر" }));

    expect(within(await dialog()).getByText(/هذا سيكون الأوردر رقم 3 له/)).toBeInTheDocument();
    expect(action).not.toHaveBeenCalled();
  });

  it("creates the order once confirmed", async () => {
    const user = userEvent.setup();
    lookup.mockResolvedValue({ ok: true, data: twoPrevious });
    render(<OrderForm regions={regions} action={action} showFactoryField={false} />);

    await fillForm(user);
    await user.click(screen.getByRole("button", { name: "إنشاء الأوردر" }));
    await dialog();
    await user.click(screen.getByRole("button", { name: "متابعة وإنشاء الأوردر" }));

    await waitFor(() => expect(action).toHaveBeenCalledTimes(1));
    expect(action.mock.calls[0][0]).toMatchObject({ customer_phone: "01012345678" });
  });

  it("creates nothing when the confirmation is dismissed", async () => {
    const user = userEvent.setup();
    lookup.mockResolvedValue({ ok: true, data: twoPrevious });
    render(<OrderForm regions={regions} action={action} showFactoryField={false} />);

    await fillForm(user);
    await user.click(screen.getByRole("button", { name: "إنشاء الأوردر" }));
    await dialog();
    await user.click(screen.getByRole("button", { name: "رجوع للتعديل" }));

    await waitFor(() => expect(screen.queryByRole("alertdialog")).not.toBeInTheDocument());
    expect(action).not.toHaveBeenCalled();
  });

  it("surfaces the open order the customer already has", async () => {
    const user = userEvent.setup();
    lookup.mockResolvedValue({ ok: true, data: twoPrevious });
    render(<OrderForm regions={regions} action={action} showFactoryField={false} />);

    await fillForm(user);
    await user.click(screen.getByRole("button", { name: "إنشاء الأوردر" }));

    const box = within(await dialog());
    expect(box.getByText(/لم يُسلَّم بعد/)).toBeInTheDocument();
    expect(box.getByText(/EL-0042/)).toBeInTheDocument();
  });

  /**
   * The failure mode the mandatory Maps link hit: the field never blurred,
   * so the on-blur work never ran. The gate has to hold on submit, not on
   * blur, which is what this pins down — the number is typed and the button
   * pressed with focus never leaving the field.
   */
  it("still checks a number that was never blurred before submitting", async () => {
    const user = userEvent.setup();
    lookup.mockResolvedValue({ ok: true, data: twoPrevious });
    render(<OrderForm regions={regions} action={action} showFactoryField={false} />);

    // Fill everything else first, then the phone last, then submit via the
    // keyboard so focus never leaves the phone input.
    await user.type(screen.getByLabelText("اسم العميل"), "سمير علي");
    await user.type(screen.getByLabelText("العنوان"), "شارع 9، المعادي");
    await user.type(
      screen.getByLabelText("رابط موقع العميل على خرائط جوجل"),
      "https://maps.app.goo.gl/abc",
    );
    await user.type(screen.getByLabelText("المنطقة"), "المعادي");
    await user.type(screen.getByLabelText("رقم الهاتف"), "01012345678{Enter}");

    expect(within(await dialog()).getByText(/هذا سيكون الأوردر رقم 3 له/)).toBeInTheDocument();
    expect(action).not.toHaveBeenCalled();
  });

  /**
   * An unavailable convenience check must never block a real order — the
   * customer is on the line.
   */
  it("creates the order anyway when the lookup fails", async () => {
    const user = userEvent.setup();
    lookup.mockResolvedValue({ ok: false, error: "تعذر التحقق" });
    render(<OrderForm regions={regions} action={action} showFactoryField={false} />);

    await fillForm(user);
    await user.click(screen.getByRole("button", { name: "إنشاء الأوردر" }));

    await waitFor(() => expect(action).toHaveBeenCalledTimes(1));
  });

  it("does not look up a half-typed number", async () => {
    const user = userEvent.setup();
    lookup.mockResolvedValue({ ok: true, data: noHistory });
    render(<OrderForm regions={regions} action={action} showFactoryField={false} />);

    await user.type(screen.getByLabelText("رقم الهاتف"), "0101");
    await user.tab();

    await waitFor(() => expect(lookup).not.toHaveBeenCalled());
  });

  it("shows the repeat line under the phone field as soon as it is blurred", async () => {
    const user = userEvent.setup();
    lookup.mockResolvedValue({ ok: true, data: twoPrevious });
    render(<OrderForm regions={regions} action={action} showFactoryField={false} />);

    await user.type(screen.getByLabelText("رقم الهاتف"), "01012345678");
    await user.tab();

    expect(await screen.findByText(/عميل مكرر — هذا سيكون الأوردر رقم 3 له/)).toBeInTheDocument();
  });

  /** A count that belongs to a different number is worse than no count. */
  it("drops the repeat line once the number is edited", async () => {
    const user = userEvent.setup();
    lookup.mockResolvedValue({ ok: true, data: twoPrevious });
    render(<OrderForm regions={regions} action={action} showFactoryField={false} />);

    const phone = screen.getByLabelText("رقم الهاتف");
    await user.type(phone, "01012345678");
    await user.tab();
    await screen.findByText(/عميل مكرر/);

    await user.type(phone, "9");
    await waitFor(() => expect(screen.queryByText(/عميل مكرر/)).not.toBeInTheDocument());
  });
});
