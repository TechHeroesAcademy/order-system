import { z } from "zod";

const phoneRegex = /^[\d+\-\s]{8,20}$/;

const mapsUrlField = z
  .string()
  .trim()
  .max(2000, "الرابط طويل جدًا")
  .optional()
  .nullable()
  .refine((v) => !v || /^https?:\/\/\S+$/i.test(v), "الصق رابط خرائط جوجل كامل (يبدأ بـ http:// أو https://)");

const requiredMapsUrlField = z
  .string({ error: "الصق رابط موقع العميل على خرائط جوجل" })
  .trim()
  .min(1, "الصق رابط موقع العميل على خرائط جوجل")
  .max(2000, "الرابط طويل جدًا")
  .regex(/^https?:\/\/\S+$/i, "الصق رابط خرائط جوجل كامل (يبدأ بـ http:// أو https://)");

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
  customer_maps_url: requiredMapsUrlField,
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
  driver_id: z.string().uuid().optional().nullable(),
});

export type OrderFormValues = z.infer<typeof orderFormSchema>;

export const editOrderSchema = orderFormSchema
  .omit({ factory_id: true, driver_id: true })
  .extend({ customer_maps_url: mapsUrlField });
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
  email: z.string().trim().email("بريد إلكتروني غير صالح").optional().or(z.literal("")),
  role: z.enum(["owner", "moderator", "driver"]),
  region_names: z
    .array(z.string().trim().min(2).max(100))
    .optional()
    .default([]),
});

export const factoryDetailsSchema = z.object({
  name: z.string().trim().min(2, "اسم المصنع مطلوب").max(120),
  phone: z.string().trim().max(30).optional().nullable(),
  address: z.string().trim().max(500).optional().nullable(),
  lat: z.number().min(-90).max(90).optional().nullable(),
  lng: z.number().min(-180).max(180).optional().nullable(),
  maps_url: mapsUrlField,
});

export const phoneLookupSchema = z.object({
  phone: z
    .string()
    .trim()
    .refine((v) => v.replace(/\D/g, "").length >= 8, "رقم الهاتف غير صالح"),
});

const newPasswordField = z.string().min(6, "كلمة المرور 6 أحرف على الأقل").max(72);

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

export const phoneLoginSchema = z.object({
  phone: z.string().trim(),
  password: z.string().min(1, "أدخل كلمة المرور"),
});

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
