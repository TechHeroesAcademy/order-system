"use client";

import { useTransition } from "react";
import { toast } from "sonner";
import { Loader2, KeyRound } from "lucide-react";
import { Button } from "@/components/ui/button";
import { setStaffActiveAction, resetStaffPasswordAction } from "@/lib/actions/admin";

/**
 * Shared row-actions used by both the workers table (TeamManager) and the
 * factories table (FactoriesMapPanel) — split out so neither imports from
 * the other (FactoriesMapPanel is rendered from inside TeamManager).
 */
export function ToggleActiveButton({
  userId,
  isActive,
  onToggled,
}: {
  userId: string;
  isActive: boolean;
  onToggled: (isActive: boolean) => void;
}) {
  const [pending, startTransition] = useTransition();

  function toggle() {
    startTransition(async () => {
      const res = await setStaffActiveAction(userId, !isActive);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      onToggled(!isActive);
      toast.success(!isActive ? "تم تفعيل الحساب" : "تم إيقاف الحساب");
    });
  }

  return (
    <Button size="sm" variant={isActive ? "outline" : "default"} onClick={toggle} disabled={pending}>
      {pending && <Loader2 className="animate-spin" />}
      {isActive ? "إيقاف" : "تفعيل"}
    </Button>
  );
}

/**
 * Invalidates the old password immediately and flips the account back to
 * "needs to set a password" — the worker just signs in with their phone
 * number as usual and is prompted to create a new one, no temp password to
 * relay over the phone.
 */
export function ResetPasswordButton({ userId }: { userId: string }) {
  const [pending, startTransition] = useTransition();

  function reset() {
    startTransition(async () => {
      const res = await resetStaffPasswordAction(userId);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      toast.success("تم إعادة تعيين كلمة المرور — سيقوم بإنشاء كلمة مرور جديدة عند تسجيل الدخول برقم هاتفه");
    });
  }

  return (
    <Button size="sm" variant="outline" onClick={reset} disabled={pending} title="إعادة تعيين كلمة المرور">
      {pending ? <Loader2 className="animate-spin" /> : <KeyRound className="size-4" />}
    </Button>
  );
}
