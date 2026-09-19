"use client";

import { useState, useTransition } from "react";
import { toast } from "sonner";
import { Loader2, KeyRound, Trash2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { setStaffActiveAction, resetStaffPasswordAction, deleteStaffAccountAction } from "@/lib/actions/admin";

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

/**
 * Owner-only, permanent — deletes the account entirely (see
 * deleteStaffAccountAction). Every order this worker ever touched keeps
 * showing their name; only the account itself is gone. Gated behind a
 * confirmation dialog like CancelOrderButton, since there's no undo here
 * either.
 */
export function DeleteStaffButton({
  userId,
  fullName,
  isDriver = false,
  onDeleted,
}: {
  userId: string;
  fullName: string;
  /** Drivers have their active orders moved before the account goes — see deleteStaffAccountAction. */
  isDriver?: boolean;
  onDeleted: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [pending, startTransition] = useTransition();

  function handleConfirm() {
    startTransition(async () => {
      const res = await deleteStaffAccountAction(userId);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      const { reassigned, resuggested, unallocated } = res.data;
      const moved = reassigned + resuggested;

      // Say what happened to their work, now, rather than leaving the manager
      // to find out later — especially the orders nobody could take.
      if (unallocated > 0) {
        toast.warning(
          `تم حذف الحساب. تم نقل ${moved} أوردر، و${unallocated} أوردر بحاجة لتعيين مندوب يدويًا — موجودة في صفحة التوزيع.`,
          { duration: 10000 },
        );
      } else if (moved > 0) {
        toast.success(`تم حذف الحساب ونقل ${moved} أوردر إلى مندوبين آخرين في نفس المنطقة`);
      } else {
        toast.success("تم حذف الحساب نهائيًا");
      }
      setOpen(false);
      onDeleted();
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button
          size="sm"
          variant="ghost"
          className="text-destructive hover:text-destructive"
          title="حذف الحساب نهائيًا"
        >
          <Trash2 className="size-4" />
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>حذف حساب {fullName} نهائيًا</DialogTitle>
          <DialogDescription>
            سيتم حذف الحساب بالكامل ولن يتمكن من تسجيل الدخول مرة أخرى. لا يمكن التراجع عن هذا الإجراء.
            أوردرات هذا الحساب تبقى محفوظة وتظهر باسمه كما هي.
            {isDriver
              ? " الأوردرات النشطة هتتنقل تلقائيًا لمندوب تاني بيغطي نفس المنطقة، وأي أوردر مفيش حد يغطيه هيتعلّم عليه عشان تعيّنه بنفسك."
              : ""}
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>
            تراجع
          </Button>
          <Button variant="destructive" onClick={handleConfirm} disabled={pending}>
            {pending && <Loader2 className="animate-spin" />}
            حذف نهائيًا
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
