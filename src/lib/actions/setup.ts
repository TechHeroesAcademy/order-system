"use server";

import { createAdminClient } from "@/lib/db/client";
import { issueSession } from "@/lib/auth/sign-in";
import { bootstrapOwnerSchema } from "@/lib/domain/validators";
import { ok, fail, type ActionResult } from "./types";
import type { z } from "zod";
import type { UserRole } from "@/types/database";

export async function ownerExists(): Promise<boolean> {
  const db = createAdminClient();

  const { data, error } = await db.rpc<boolean>("owner_exists");

  if (error) {
    console.error("[setup] owner_exists() failed:", error.message);
    return true;
  }
  return data === true;
}

export async function bootstrapOwnerAction(
  input: z.infer<typeof bootstrapOwnerSchema>,
): Promise<ActionResult> {
  const parsed = bootstrapOwnerSchema.safeParse(input);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");

  const db = createAdminClient();
  const { data, error } = await db.rpc<{ status: string; profile_id: string | null }[]>(
    "bootstrap_owner",
    {
      p_full_name: parsed.data.full_name,
      p_phone: parsed.data.phone,
      p_password: parsed.data.password,
    },
  );
  if (error) return fail("تعذر إنشاء الحساب");

  const row = data?.[0];
  switch (row?.status) {
    case "ok":
      break;
    case "already_set_up":
      return fail("تم إعداد حساب المدير بالفعل — سجّل الدخول من صفحة الدخول");
    case "phone_taken":
      return fail("رقم الهاتف مستخدم بالفعل لحساب آخر");
    case "weak_password":
      return fail("كلمة المرور 6 أحرف على الأقل");
    case "invalid_name":
      return fail("الاسم قصير جدًا");
    case "invalid_phone":
      return fail("رقم الهاتف غير صالح");
    default:
      return fail("تعذر إنشاء الحساب");
  }

  if (!row.profile_id) return fail("تعذر إنشاء الحساب");

  await issueSession({
    id: row.profile_id,
    role: "owner" satisfies UserRole,
    full_name: parsed.data.full_name,
  });

  return ok(undefined);
}
