/** Consistent Server Action result shape so client components don't need try/catch. */
export type ActionResult<T = undefined> =
  | { ok: true; data: T }
  | { ok: false; error: string };

export function ok<T>(data: T): ActionResult<T> {
  return { ok: true, data };
}

export function fail(error: string): ActionResult<never> {
  return { ok: false, error };
}

/** Supabase/Postgres errors surface here; RPC-raised messages are already Arabic. */
export function toErrorMessage(error: unknown, fallback = "حدث خطأ غير متوقع"): string {
  if (error && typeof error === "object" && "message" in error) {
    const message = String((error as { message?: unknown }).message ?? "");
    if (message) return message;
  }
  return fallback;
}
