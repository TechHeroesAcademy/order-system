import { z } from "zod";

/** Egyptian-friendly loose phone validation: digits, spaces, +, - allowed, 8-15 digits total. */
const phoneRegex = /^[\d+\-\s]{8,20}$/;

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
  region_id: z.string().uuid("اختر المنطقة").nullable(),
  pieces_count: z
    .number()
    .int("عدد القطع يجب أن يكون رقمًا صحيحًا")
    .min(1, "عدد القطع يجب أن يكون 1 على الأقل")
    .max(999),
  piece_details: z.string().trim().max(500).optional().nullable(),
  color: z.string().trim().max(100).optional().nullable(),
  work_required: z.string().trim().max(500).optional().nullable(),
  customer_notes: z.string().trim().max(1000).optional().nullable(),
});

export type OrderFormValues = z.infer<typeof orderFormSchema>;

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

export const refusalReasonSchema = z.object({
  reason: z.string().trim().min(3, "اكتب سبب الرفض").max(500),
});

export const cancelOrderSchema = z.object({
  reason: z.string().trim().min(3, "اكتب سبب الإلغاء").max(500),
});

export const regionNameSchema = z.object({
  name: z.string().trim().min(2, "اسم المنطقة قصير جدًا").max(100),
});

export const loginSchema = z.object({
  email: z.string().trim().email("بريد إلكتروني غير صالح"),
  password: z.string().min(6, "كلمة المرور قصيرة جدًا"),
});

export type LoginValues = z.infer<typeof loginSchema>;

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
  region_ids: z.array(z.string().uuid()).optional().default([]),
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
