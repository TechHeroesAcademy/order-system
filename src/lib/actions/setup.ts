"use server";

import { createAdminClient } from "@/lib/supabase/admin";
import { createClient } from "@/lib/supabase/server";
import { normalizePhone } from "@/lib/domain/phone";
import { bootstrapOwnerSchema } from "@/lib/domain/validators";
import { ok, fail, toErrorMessage, type ActionResult } from "./types";
import type { z } from "zod";

/**
 * Whether the system already has an Owner account. Used both to decide what
 * /setup renders (UX) and, again, inside bootstrapOwnerAction right before
 * creating the account (enforcement) — the page-level check alone isn't
 * enough since it runs once at request time.
 */
export async function ownerExists(): Promise<boolean> {
  const admin = createAdminClient();
  const { count } = await admin
    .from("profiles")
    .select("id", { count: "exact", head: true })
    .eq("role", "owner");
  return (count ?? 0) > 0;
}

/**
 * One-time, self-service Owner bootstrap — replaces the old "create the
 * first account via the Supabase dashboard with an email" instructions.
 * No email is ever involved: the Owner picks their own phone number and
 * password right here, and signs themselves in immediately after.
 */
export async function bootstrapOwnerAction(
  input: z.infer<typeof bootstrapOwnerSchema>,
): Promise<ActionResult> {
  const parsed = bootstrapOwnerSchema.safeParse(input);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");

  if (await ownerExists()) {
    return fail("تم إعداد حساب صاحب النظام بالفعل — سجّل الدخول من صفحة الدخول");
  }

  const admin = createAdminClient();
  const normalizedPhone = normalizePhone(parsed.data.phone);

  const { data: existingPhone } = await admin
    .from("profiles")
    .select("id")
    .eq("phone", normalizedPhone)
    .maybeSingle();
  if (existingPhone) return fail("رقم الهاتف مستخدم بالفعل لحساب آخر");

  // Synthetic internal address — never shown to the Owner or used for login.
  // Unlike staff accounts, the Owner sets their own real password right now,
  // so password_set stays at its default (true): no "create a password"
  // step needed the first time they log in with their phone number.
  const email = `owner-${crypto.randomUUID()}@workers.internal`;

  const { data, error } = await admin.auth.admin.createUser({
    email,
    password: parsed.data.password,
    email_confirm: true,
    user_metadata: {
      full_name: parsed.data.full_name,
      phone: normalizedPhone,
      role: "owner",
    },
  });

  if (error || !data.user) {
    return fail(toErrorMessage(error, "تعذر إنشاء الحساب"));
  }

  const supabase = await createClient();
  const { error: signInErr } = await supabase.auth.signInWithPassword({
    email,
    password: parsed.data.password,
  });
  if (signInErr) {
    return fail("تم إنشاء الحساب، لكن فشل تسجيل الدخول التلقائي — سجّل الدخول من صفحة الدخول برقم هاتفك");
  }

  return ok(undefined);
}
