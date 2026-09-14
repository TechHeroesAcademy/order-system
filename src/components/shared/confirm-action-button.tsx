"use client";

import { useState, useTransition } from "react";
import { toast } from "sonner";
import { Button, type buttonVariants } from "@/components/ui/button";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
  AlertDialogTrigger,
} from "@/components/ui/alert-dialog";
import { Loader2 } from "lucide-react";
import type { VariantProps } from "class-variance-authority";
import type { ActionResult } from "@/lib/actions/types";

export function ConfirmActionButton({
  label,
  confirmTitle,
  confirmDescription,
  onConfirm,
  successMessage,
  variant = "default",
  icon,
  disabled,
}: {
  label: string;
  confirmTitle: string;
  confirmDescription?: string;
  onConfirm: () => Promise<ActionResult<unknown>>;
  successMessage?: string;
  variant?: VariantProps<typeof buttonVariants>["variant"];
  icon?: React.ReactNode;
  disabled?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [pending, startTransition] = useTransition();

  function handleConfirm() {
    startTransition(async () => {
      const result = await onConfirm();
      if (!result.ok) {
        toast.error(result.error);
        return;
      }
      toast.success(successMessage ?? "تم التنفيذ بنجاح");
      setOpen(false);
    });
  }

  return (
    <AlertDialog open={open} onOpenChange={setOpen}>
      <AlertDialogTrigger asChild>
        <Button variant={variant} disabled={disabled}>
          {icon}
          {label}
        </Button>
      </AlertDialogTrigger>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle>{confirmTitle}</AlertDialogTitle>
          {confirmDescription && <AlertDialogDescription>{confirmDescription}</AlertDialogDescription>}
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel disabled={pending}>إلغاء</AlertDialogCancel>
          <AlertDialogAction onClick={handleConfirm} disabled={pending}>
            {pending && <Loader2 className="animate-spin" />}
            تأكيد
          </AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
