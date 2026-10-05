import { describe, it, expect } from "vitest";
import { orderFormSchema, editOrderSchema } from "../validators";

const NEW_ORDER = {
  customer_name: "عميل",
  customer_phone: "01012345678",
  customer_address: "شارع شبرا الرئيسي",
  region_name: "شبرا",
  pieces_count: 2,
  factory_id: "3f2504e0-4f89-41d3-9a0c-0305e82c3301",
  driver_id: null,
};

const OLD_ORDER_EDIT = {
  customer_name: "عميل",
  customer_phone: "01012345678",
  customer_address: "شارع شبرا الرئيسي",
  region_name: "شبرا",
  pieces_count: 2,
};

describe("customer Maps link — required to create", () => {
  it("accepts a real Maps link", () => {
    const r = orderFormSchema.safeParse({
      ...NEW_ORDER,
      customer_maps_url: "https://maps.app.goo.gl/abc123",
    });
    expect(r.success).toBe(true);
  });

  it.each([
    ["missing entirely", undefined],
    ["empty string", ""],
    ["whitespace only", "   "],
  ])("rejects when %s", (_label, value) => {
    const r = orderFormSchema.safeParse({ ...NEW_ORDER, customer_maps_url: value });
    expect(r.success).toBe(false);
  });

  it("rejects text that is not a link, rather than storing something unusable", () => {
    const r = orderFormSchema.safeParse({ ...NEW_ORDER, customer_maps_url: "شبرا" });
    expect(r.success).toBe(false);
  });
});

describe("customer Maps link — optional to edit", () => {
  it("lets an order created before the rule be edited without one", () => {
    const r = editOrderSchema.safeParse(OLD_ORDER_EDIT);
    expect(r.success).toBe(true);
  });

  it("still validates the link's shape when one is supplied", () => {
    expect(editOrderSchema.safeParse({ ...OLD_ORDER_EDIT, customer_maps_url: "not-a-url" }).success).toBe(false);
    expect(
      editOrderSchema.safeParse({ ...OLD_ORDER_EDIT, customer_maps_url: "https://maps.app.goo.gl/x" }).success,
    ).toBe(true);
  });
});
