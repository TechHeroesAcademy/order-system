"use client";

import { useState, useTransition } from "react";
import { toast } from "sonner";
import { Loader2, Trash2 } from "lucide-react";
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
import { setFactoryActiveAction, deleteFactoryAction } from "@/lib/actions/factories";

export function ToggleFactoryActiveButton({
  factoryId,
  isActive,
  onToggled,
}: {
  factoryId: string;
  isActive: boolean;
  onToggled: (isActive: boolean) => void;
}) {
  const [pending, startTransition] = useTransition();

  function toggle() {
    startTransition(async () => {
      const res = await setFactoryActiveAction(factoryId, !isActive);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      onToggled(!isActive);
      toast.success(!isActive ? "تم تفعيل المصنع" : "تم تعطيل المصنع");
    });
  }

  return (
    <Button size="sm" variant={isActive ? "outline" : "default"} onClick={toggle} disabled={pending}>
      {pending && <Loader2 className="animate-spin" />}
      {isActive ? "تعطيل" : "تفعيل"}
    </Button>
  );
}

export function DeleteFactoryButton({
  factoryId,
  name,
  onDeleted,
}: {
  factoryId: string;
  name: string;
  onDeleted: () => void;
}) {
  const [open, setOpen] = useState(false);
  const [pending, startTransition] = useTransition();

  function remove() {
    startTransition(async () => {
      const res = await deleteFactoryAction(factoryId);
      if (!res.ok) {
        toast.error(res.error);
        setOpen(false);
        return;
      }
      onDeleted();
      setOpen(false);
      toast.success("تم حذف المصنع");
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button size="sm" variant="outline" title="حذف المصنع">
          <Trash2 className="size-4 text-destructive" />
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>حذف المصنع</DialogTitle>
          <DialogDescription>
            سيتم حذف «{name}» نهائيًا. لا يمكن حذف مصنع مرتبط بأوردرات سابقة — استخدم «تعطيل» بدلًا من ذلك
            حتى تظل بيانات الأوردرات القديمة سليمة.
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>
            إلغاء
          </Button>
          <Button variant="destructive" onClick={remove} disabled={pending}>
            {pending && <Loader2 className="animate-spin" />}
            حذف
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
