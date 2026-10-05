"use server";

import { revalidatePath } from "next/cache";
import { z } from "zod";
import { requireRole } from "@/lib/auth";
import { createClient } from "@/lib/db/client";
import { ok, fail, toErrorMessage, type ActionResult } from "./types";

const factorySchema = z.object({
  name: z.string().trim().min(2, "اسم المصنع مطلوب"),
  phone: z.string().trim().optional().nullable(),
  address: z.string().trim().optional().nullable(),
  lat: z.number().nullable().optional(),
  lng: z.number().nullable().optional(),
  maps_url: z.string().trim().optional().nullable(),
});

export type FactoryInput = z.infer<typeof factorySchema>;

function revalidateFactoryViews() {
  revalidatePath("/owner/team");
  revalidatePath("/owner");
  revalidatePath("/moderator");
  revalidatePath("/driver");
}

export async function createFactoryAction(input: FactoryInput): Promise<ActionResult<{ id: string }>> {
  await requireRole("owner");
  const parsed = factorySchema.safeParse(input);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");

  const supabase = await createClient();
  const { data, error } = await supabase.rpc("create_factory", {
    p_name: parsed.data.name,
    p_phone: parsed.data.phone ?? null,
    p_address: parsed.data.address ?? null,
    p_lat: parsed.data.lat ?? null,
    p_lng: parsed.data.lng ?? null,
    p_maps_url: parsed.data.maps_url ?? null,
  });
  if (error) return fail(toErrorMessage(error, "تعذر إضافة المصنع"));

  revalidateFactoryViews();
  return ok({ id: data as string });
}

export async function updateFactoryAction(
  factoryId: string,
  input: FactoryInput,
): Promise<ActionResult> {
  await requireRole("owner", "moderator");
  const parsed = factorySchema.safeParse(input);
  if (!parsed.success) return fail(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");

  const supabase = await createClient();
  const { error } = await supabase.rpc("update_factory", {
    p_factory_id: factoryId,
    p_name: parsed.data.name,
    p_phone: parsed.data.phone ?? null,
    p_address: parsed.data.address ?? null,
    p_lat: parsed.data.lat ?? null,
    p_lng: parsed.data.lng ?? null,
    p_maps_url: parsed.data.maps_url ?? null,
  });
  if (error) return fail(toErrorMessage(error, "تعذر تحديث بيانات المصنع"));

  revalidateFactoryViews();
  return ok(undefined);
}

export async function setFactoryActiveAction(
  factoryId: string,
  isActive: boolean,
): Promise<ActionResult> {
  await requireRole("owner", "moderator");

  const supabase = await createClient();
  const { error } = await supabase.rpc("set_factory_active", {
    p_factory_id: factoryId,
    p_is_active: isActive,
  });
  if (error) return fail(toErrorMessage(error, "تعذر تغيير حالة المصنع"));

  revalidateFactoryViews();
  return ok(undefined);
}

export async function deleteFactoryAction(factoryId: string): Promise<ActionResult> {
  await requireRole("owner");

  const supabase = await createClient();
  const { error } = await supabase.rpc("delete_factory", { p_factory_id: factoryId });
  if (error) return fail(toErrorMessage(error, "تعذر حذف المصنع"));

  revalidateFactoryViews();
  return ok(undefined);
}
