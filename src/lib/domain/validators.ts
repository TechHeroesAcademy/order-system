import { z } from "zod";

/** Egyptian-friendly loose phone validation: digits, spaces, +, - allowed, 8-15 digits total. */
const phoneRegex = /^[\d+\-\s]{8,20}$/;

/**
 * A pasted Google Maps link — e.g. a "share link" copied from the Maps app
 * (Share > Copy link), which can be a long .../maps/place/... URL carrying
 * its own precise coordinates, or a shortened maps.app.goo.gl one. Loosely
 * validated (just "looks like an http(s) URL") rather than with z.string().url()
 * — Maps share links can be very long with unusual query characters, and the
 * point here is just to catch an obvious typo/non-link paste, not to
 * validate Google's URL format.
 */
const mapsUrlField = z
  .string()
  .trim()
  .max(2000, "الرابط طويل جدًا")
  .optional()
  .nullable()
  .refine((v) => !v || /^https?:\/\/\S+$/i.test(v), "الصق رابط خرائط جوجل كامل (يبدأ بـ http:// أو https://)");

export const orderFormSchema = z.object({
  customer_name: z
    .string()
    .trim()
    .min(2, "الاسم قصير جدًا")
    .max(120, "الاسم طويل جدًا"),
  customer_phone: z
    .string()
    .trim()
    .regex(phoneRegex, "رقم الهاتف غير صالح")
    .refine((v) => v.replace(/\D/g, "").length >= 8, "رقم الهاتف غير صالح"),
  customer_address: z
    .string()
    .trim()
    .min(5, "العنوان قصير جدًا")
    .max(500, "العنوان طويل جدًا"),
  // Optional pasted Google Maps link for the customer's exact location —
  // preferred over a text search of customer_address whenever present (see
  // mapsUrlFor). Independent of customer_address, which stays required as
  // the human-readable fallback and is always shown regardless.
  customer_maps_url: mapsUrlField,
  // Typed by keyboard, not picked from a list (see migration 0025) — and
  // mandatory: a blank/whitespace-only value fails here before it ever
  // reaches find_or_create_region()'s own (defense-in-depth) check.
  region_name: z
    .string()
    .trim()
    .min(2, "اكتب اسم المنطقة")
    .max(100, "اسم المنطقة طويل جدًا"),
  pieces_count: z
    .number()
    .int("عدد القطع يجب أن يكون رقمًا صحيحًا")
    .min(1, "عدد القطع يجب أن يكون 1 على الأقل")
    .max(999),
  piece_details: z.string().trim().max(500).optional().nullable(),
  color: z.string().trim().max(100).optional().nullable(),
  work_required: z.string().trim().max(500).optional().nullable(),
  customer_notes: z.string().trim().max(1000).optional().nullable(),
  factory_id: z.string().uuid().optional().nullable(),
  // Optional at the schema level — Owner can still leave these unassigned
  // (handled later through the separate distribution flow). Moderator is
  // required to pick both, but that's a role-based UI rule, not something
  // this shared schema can express; see OrderForm's requireDriverAndFactory
  // prop and createModeratorOrderAction's own server-side check.
  driver_id: z.string().uuid().optional().nullable(),
});

export type OrderFormValues = z.infer<typeof orderFormSchema>;

/**
 * Owner/Moderator editing an *existing* order's details after creation
 * (updateOrderDetailsAction / update_order_details). Every field an order
 * carries about the customer/job is editable this way; only the
 * distribution fields (factory_id/driver_id — reassigned through their own
 * dedicated flow, see ChangeDriverButton/ChangeFactoryButton) are excluded.
 */
export const editOrderSchema = orderFormSchema.omit({ factory_id: true, driver_id: true });
export type EditOrderValues = z.infer<typeof editOrderSchema>;

export const trackOrderSchema = z.object({
  order_number: z
    .string()
    .trim()
    .min(3, "أدخل رقم الأوردر")
    .transform((v) => v.toUpperCase()),
  phone: z
    .string()
    .trim()
    .refine((v) => v.replace(/\D/g, "").length >= 8, "رقم الهاتف غير صالح"),
});

export type TrackOrderValues = z.infer<typeof trackOrderSchema>;

export const deliveryCodeSchema = z.object({
  code: z
    .string()
    .trim()
    .regex(/^\d{4}$/, "الكود مكوّن من 4 أرقام"),
});

/** Same 4-digit shape as deliveryCodeSchema, kept as its own export for the pickup-from-customer step (migration 0024) — same code format, different meaning. */
export const pickupCodeSchema = deliveryCodeSchema;

export const refusalReasonSchema = z.object({
  reason: z.string().trim().min(3, "اكتب سبب الرفض").max(500),
});

export const cancelOrderSchema = z.object({
  reason: z.string().trim().min(3, "اكتب سبب الإلغاء").max(500),
});

export const regionNameSchema = z.object({
  name: z.string().trim().min(2, "اسم المنطقة قصير جدًا").max(100),
});

export const createStaffAccountSchema = z.object({
  full_name: z.string().trim().min(2, "الاسم قصير جدًا").max(120),
  phone: z
    .string()
    .trim()
    .regex(phoneRegex, "رقم الهاتف غير صالح")
    .refine((v) => v.replace(/\D/g, "").length >= 8, "رقم الهاتف غير صالح"),
  // Optional: most staff (drivers/factory workers especially) sign in with
  // their phone number and never need an email. When left blank we generate
  // an internal one — it's never shown to them or used for login.
  email: z.string().trim().email("بريد إلكتروني غير صالح").optional().or(z.literal("")),
  role: z.enum(["owner", "moderator", "driver", "factory"]),
  // Typed area names, not ids picked from a checkbox list (migration
  // 0025) — resolved/auto-created server-side via find_or_create_region().
  region_names: z
    .array(z.string().trim().min(2).max(100))
    .optional()
    .default([]),
  // Only meaningful for role="factory" — where the driver drops off/picks
  // up orders. Left optional rather than required-when-factory so an
  // existing flow that doesn't collect it yet (or a factory added before a
  // location is known) still works; it can be filled in later.
  address: z.string().trim().max(500).optional().nullable(),
  // Precise coordinates from the map picker, alongside the free-text
  // address above — also optional/fill-in-later for the same reason.
  lat: z.number().min(-90).max(90).optional().nullable(),
  lng: z.number().min(-180).max(180).optional().nullable(),
  // Optional pasted Google Maps link — preferred over lat/lng/address in
  // mapsUrlFor() whenever present, same idea as the order form's field above.
  maps_url: mapsUrlField,
});

/** Owner/Moderator editing an existing factory account's location. */
export const updateStaffLocationSchema = z.object({
  address: z.string().trim().max(500).nullable(),
  maps_url: mapsUrlField,
  lat: z.number().min(-90).max(90).nullable(),
  lng: z.number().min(-180).max(180).nullable(),
});

/** Step 1 of the phone-based login: just the phone number. */
export const phoneLookupSchema = z.object({
  phone: z
    .string()
    .trim()
    .refine((v) => v.replace(/\D/g, "").length >= 8, "رقم الهاتف غير صالح"),
});

const newPasswordField = z.string().min(6, "كلمة المرور 6 أحرف على الأقل").max(72);

/** Step 2a: first-ever login — the worker creates their own password. */
export const setInitialPasswordSchema = z
  .object({
    phone: z.string().trim(),
    password: newPasswordField,
    confirmPassword: z.string(),
  })
  .refine((v) => v.password === v.confirmPassword, {
    message: "كلمتا المرور غير متطابقتين",
    path: ["confirmPassword"],
  });

/** Step 2b: returning login — phone + the password they already set. */
export const phoneLoginSchema = z.object({
  phone: z.string().trim(),
  password: z.string().min(1, "أدخل كلمة المرور"),
});

/** First-run self-service Owner setup — no email, no dashboard step. */
export const bootstrapOwnerSchema = z
  .object({
    full_name: z.string().trim().min(2, "الاسم قصير جدًا").max(120),
    phone: z
      .string()
      .trim()
      .refine((v) => v.replace(/\D/g, "").length >= 8, "رقم الهاتف غير صالح"),
    password: newPasswordField,
    confirmPassword: z.string(),
  })
  .refine((v) => v.password === v.confirmPassword, {
    message: "كلمتا المرور غير متطابقتين",
    path: ["confirmPassword"],
  });

export type BootstrapOwnerValues = z.infer<typeof bootstrapOwnerSchema>;
