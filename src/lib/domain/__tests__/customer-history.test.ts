import { describe, expect, it } from "vitest";
import {
  buildCustomerSequenceNote,
  buildRepeatCustomerNotice,
  isPhoneLookupReady,
  phoneMatchKey,
} from "@/lib/domain/customer-history";
import type { CustomerOrderHistory, OrderCustomerContext } from "@/types/database";

const empty: CustomerOrderHistory = {
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

function history(over: Partial<CustomerOrderHistory>): CustomerOrderHistory {
  return { ...empty, ...over };
}

describe("phoneMatchKey", () => {
  it("reduces every way one Egyptian number gets written to the same key", () => {
    const keys = [
      "01012345678",
      "+201012345678",
      "00201012345678",
      "010-1234-5678",
      "010 1234 5678",
    ].map(phoneMatchKey);

    expect(new Set(keys).size).toBe(1);
    expect(keys[0]).toBe("12345678");
  });

  it("treats a half-typed number as not ready to look up", () => {
    expect(isPhoneLookupReady("0101")).toBe(false);
    expect(isPhoneLookupReady("")).toBe(false);
    expect(isPhoneLookupReady("01012345678")).toBe(true);
  });
});

describe("buildRepeatCustomerNotice", () => {
  it("says nothing at all for a customer with no history", () => {
    const notice = buildRepeatCustomerNotice(empty, "سمير");
    expect(notice.isRepeat).toBe(false);
    expect(notice.openWarning).toBeNull();
    expect(notice.nameMismatch).toBeNull();
  });

  it("numbers this order as one past the count of previous ones", () => {
    const notice = buildRepeatCustomerNotice(
      history({ previous_orders: 4, delivered_orders: 4 }),
      "سمير علي",
    );
    expect(notice.isRepeat).toBe(true);
    expect(notice.orderIndex).toBe(5);
    expect(notice.title).toContain("رقم 5");
  });

  it("uses singular wording for a customer with exactly one previous order", () => {
    const notice = buildRepeatCustomerNotice(
      history({ previous_orders: 1, delivered_orders: 1 }),
      "سمير",
    );
    expect(notice.orderIndex).toBe(2);
    expect(notice.title).toContain("أوردر واحد سابق");
    expect(notice.title).not.toContain("1 أوردرات");
  });

  it("breaks the history down and omits the buckets that are empty", () => {
    const notice = buildRepeatCustomerNotice(
      history({ previous_orders: 4, delivered_orders: 2, open_orders: 1, cancelled_orders: 1 }),
      "سمير",
    );
    expect(notice.breakdown).toContain("2 تم تسليمها");
    expect(notice.breakdown).toContain("1 ما زالت جارية");
    expect(notice.breakdown).toContain("1 ملغاة");
    expect(notice.breakdown).not.toContain("رفض");
  });

  it("warns separately when the customer still has an order in flight", () => {
    const notice = buildRepeatCustomerNotice(
      history({ previous_orders: 2, delivered_orders: 1, open_orders: 1 }),
      "سمير",
    );
    expect(notice.openWarning).toContain("لم يُسلَّم بعد");
  });

  it("stays quiet about open orders when everything is finished", () => {
    const notice = buildRepeatCustomerNotice(
      history({ previous_orders: 3, delivered_orders: 2, refused_orders: 1 }),
      "سمير",
    );
    expect(notice.openWarning).toBeNull();
  });

  it("includes the last order's number, date and status", () => {
    const notice = buildRepeatCustomerNotice(
      history({
        previous_orders: 1,
        delivered_orders: 1,
        last_order_number: "EL-0004",
        last_order_at: "2026-09-20T10:00:00Z",
        last_order_status: "delivered",
      }),
      "سمير",
    );
    expect(notice.lastOrderLine).toContain("EL-0004");
    expect(notice.lastOrderLine).toContain("2026");
    expect(notice.lastOrderLine).toContain("تم التسليم");
  });

  it("drops the date rather than rendering an unparseable one", () => {
    const notice = buildRepeatCustomerNotice(
      history({ previous_orders: 1, last_order_number: "EL-0004", last_order_at: "not a date" }),
      "سمير",
    );
    expect(notice.lastOrderLine).toContain("EL-0004");
    expect(notice.lastOrderLine).not.toContain("Invalid");
  });

  describe("name check", () => {
    it("flags a number saved under a different name — a likely wrong number", () => {
      const notice = buildRepeatCustomerNotice(
        history({ previous_orders: 2, names_seen: ["منى حسن"] }),
        "سمير علي",
      );
      expect(notice.nameMismatch).toContain("منى حسن");
    });

    it("says nothing when the typed name is one of the names on file", () => {
      const notice = buildRepeatCustomerNotice(
        history({ previous_orders: 2, names_seen: ["سمير علي", "سمير ع."] }),
        "سمير علي",
      );
      expect(notice.nameMismatch).toBeNull();
    });

    it("ignores differences in whitespace", () => {
      const notice = buildRepeatCustomerNotice(
        history({ previous_orders: 1, names_seen: ["سمير علي"] }),
        "  سمير   علي  ",
      );
      expect(notice.nameMismatch).toBeNull();
    });

    it("says nothing before a name has been typed", () => {
      const notice = buildRepeatCustomerNotice(
        history({ previous_orders: 1, names_seen: ["سمير علي"] }),
        "",
      );
      expect(notice.nameMismatch).toBeNull();
    });

    it("lists every name on file when more than one differs", () => {
      const notice = buildRepeatCustomerNotice(
        history({ previous_orders: 3, names_seen: ["منى حسن", "حسن منى"] }),
        "سمير",
      );
      expect(notice.nameMismatch).toContain("منى حسن");
      expect(notice.nameMismatch).toContain("حسن منى");
    });
  });
});

describe("buildCustomerSequenceNote", () => {
  function context(over: Partial<OrderCustomerContext> = {}): OrderCustomerContext {
    return {
      customer_order_index: 1,
      total_orders: 1,
      other_open_orders: 0,
      previous_order_id: null,
      previous_order_number: null,
      previous_order_at: null,
      previous_order_status: null,
      ...over,
    };
  }

  it("shows nothing for a customer with a single order", () => {
    expect(buildCustomerSequenceNote(context())).toBeNull();
  });

  it("shows nothing when the lookup was unavailable", () => {
    expect(buildCustomerSequenceNote(null)).toBeNull();
  });

  it("states this order's own position, not the customer's total plus one", () => {
    const note = buildCustomerSequenceNote(context({ customer_order_index: 3, total_orders: 4 }));
    expect(note?.headline).toContain("رقم 3 من 4");
  });

  it("numbers the first order in a long history as 1", () => {
    const note = buildCustomerSequenceNote(context({ customer_order_index: 1, total_orders: 5 }));
    expect(note?.headline).toContain("رقم 1 من 5");
  });

  it("warns when the customer has another order still open", () => {
    const note = buildCustomerSequenceNote(
      context({ customer_order_index: 2, total_orders: 2, other_open_orders: 1 }),
    );
    expect(note?.openWarning).toContain("أوردر آخر");
    expect(note?.openWarning).toContain("لم يُسلَّم بعد");
  });

  it("pluralises more than one other open order", () => {
    const note = buildCustomerSequenceNote(
      context({ customer_order_index: 4, total_orders: 4, other_open_orders: 2 }),
    );
    expect(note?.openWarning).toContain("2 أوردرات أخرى");
  });

  it("stays quiet when the customer has nothing else open", () => {
    const note = buildCustomerSequenceNote(
      context({ customer_order_index: 2, total_orders: 2, other_open_orders: 0 }),
    );
    expect(note?.openWarning).toBeNull();
  });

  it("links the order immediately before this one", () => {
    const note = buildCustomerSequenceNote(
      context({
        customer_order_index: 2,
        total_orders: 2,
        previous_order_id: "11111111-1111-1111-1111-111111111111",
        previous_order_number: "EL-0003",
        previous_order_at: "2026-06-11T09:00:00Z",
        previous_order_status: "delivered",
      }),
    );
    expect(note?.previous?.id).toBe("11111111-1111-1111-1111-111111111111");
    expect(note?.previous?.label).toContain("EL-0003");
    expect(note?.previous?.label).toContain("تم التسليم");
  });

  it("offers no link when there is no earlier order", () => {
    const note = buildCustomerSequenceNote(context({ customer_order_index: 1, total_orders: 3 }));
    expect(note?.previous).toBeNull();
  });
});
