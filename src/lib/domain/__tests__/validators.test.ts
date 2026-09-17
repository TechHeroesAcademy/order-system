import { describe, expect, it } from "vitest";
import {
  deliveryCodeSchema,
  orderFormSchema,
  trackOrderSchema,
} from "@/lib/domain/validators";

describe("orderFormSchema", () => {
  const base = {
    customer_name: "أحمد علي",
    customer_phone: "01012345678",
    customer_address: "مدينة نصر، شارع مصطفى النحاس",
    region_name: "مدينة نصر",
    pieces_count: 2,
    piece_details: "كرسيين",
    color: "بني",
    work_required: "تنجيد",
    customer_notes: null,
  };

  it("accepts a valid order", () => {
    const result = orderFormSchema.safeParse(base);
    expect(result.success).toBe(true);
  });

  it("rejects a name that is too short", () => {
    const result = orderFormSchema.safeParse({ ...base, customer_name: "أ" });
    expect(result.success).toBe(false);
  });

  it("rejects an invalid phone number", () => {
    const result = orderFormSchema.safeParse({ ...base, customer_phone: "abc" });
    expect(result.success).toBe(false);
  });

  it("rejects zero or negative pieces_count", () => {
    expect(orderFormSchema.safeParse({ ...base, pieces_count: 0 }).success).toBe(false);
    expect(orderFormSchema.safeParse({ ...base, pieces_count: -3 }).success).toBe(false);
  });

  // As of migration 0025, المنطقة is typed by keyboard and mandatory — no
  // longer a nullable dropdown pick (see order-form.tsx / find_or_create_region()).
  it("rejects a blank region_name", () => {
    expect(orderFormSchema.safeParse({ ...base, region_name: "" }).success).toBe(false);
    expect(orderFormSchema.safeParse({ ...base, region_name: "   " }).success).toBe(false);
  });

  it("rejects a region_name that's too short", () => {
    expect(orderFormSchema.safeParse({ ...base, region_name: "أ" }).success).toBe(false);
  });

  it("accepts a pasted Google Maps link for the customer", () => {
    const result = orderFormSchema.safeParse({
      ...base,
      customer_maps_url: "https://www.google.com/maps/place/Nasr+City,+Cairo/@30.05,31.32,3052m",
    });
    expect(result.success).toBe(true);
  });

  it("leaves customer_maps_url optional", () => {
    expect(orderFormSchema.safeParse(base).success).toBe(true);
    expect(orderFormSchema.safeParse({ ...base, customer_maps_url: "" }).success).toBe(true);
  });

  it("rejects a customer_maps_url that isn't a link", () => {
    const result = orderFormSchema.safeParse({ ...base, customer_maps_url: "مدينة نصر" });
    expect(result.success).toBe(false);
  });
});

describe("trackOrderSchema", () => {
  it("uppercases the order number", () => {
    const result = trackOrderSchema.parse({ order_number: "ord-0012", phone: "01099998866" });
    expect(result.order_number).toBe("ORD-0012");
  });

  it("rejects a too-short phone", () => {
    const result = trackOrderSchema.safeParse({ order_number: "ORD-0012", phone: "123" });
    expect(result.success).toBe(false);
  });
});

describe("deliveryCodeSchema", () => {
  it("accepts a 4-digit code", () => {
    expect(deliveryCodeSchema.safeParse({ code: "4037" }).success).toBe(true);
  });

  it("rejects non-4-digit input", () => {
    expect(deliveryCodeSchema.safeParse({ code: "40" }).success).toBe(false);
    expect(deliveryCodeSchema.safeParse({ code: "abcd" }).success).toBe(false);
    expect(deliveryCodeSchema.safeParse({ code: "40371" }).success).toBe(false);
  });
});
