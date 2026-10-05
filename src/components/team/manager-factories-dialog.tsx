"use client";

import { useState, useTransition } from "react";
import { toast } from "sonner";
import { Factory as FactoryIcon, Loader2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { setManagerFactoriesAction } from "@/lib/actions/push";
import type { Factory } from "@/types/database";

export function ManagerFactoriesButton({
  managerId,
  managerName,
  factories,
  assignedIds,
  onSaved,
}: {
  managerId: string;
  managerName: string;
  factories: Factory[];
  assignedIds: string[];
  onSaved: (factoryIds: string[]) => void;
}) {
  const [open, setOpen] = useState(false);
  const [selected, setSelected] = useState<string[]>(assignedIds);
  const [pending, startTransition] = useTransition();

  function openChange(next: boolean) {
    if (next) setSelected(assignedIds);
    setOpen(next);
  }

  function toggle(factoryId: string, checked: boolean) {
    setSelected((current) =>
      checked ? [...current, factoryId] : current.filter((id) => id !== factoryId),
    );
  }

  function save() {
    startTransition(async () => {
      const result = await setManagerFactoriesAction(managerId, selected);
      if (!result.ok) {
        toast.error(result.error);
        return;
      }
      onSaved(selected);
      toast.success("تم حفظ تغطية المصانع");
      setOpen(false);
    });
  }

  return (
    <Dialog open={open} onOpenChange={openChange}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm" title="تغطية المصانع">
          <FactoryIcon className="size-4" />
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>تغطية المصانع — {managerName}</DialogTitle>
          <DialogDescription>
            تحدد المصانع التي تصل إشعارات محادثاتها على هاتف هذا المدير. لا تغيّر ما يراه داخل
            التطبيق: كل المديرين يرون كل الأوردرات وكل الإشعارات في الجرس كما هو.
          </DialogDescription>
        </DialogHeader>

        {factories.length === 0 ? (
          <p className="text-sm text-muted-foreground">لا توجد مصانع مضافة بعد.</p>
        ) : (
          <div className="space-y-2">
            {factories.map((factory) => (
              <label
                key={factory.id}
                className="flex cursor-pointer items-center gap-2 rounded-md border p-2 text-sm hover:bg-accent/40"
              >
                <Checkbox
                  checked={selected.includes(factory.id)}
                  onCheckedChange={(checked) => toggle(factory.id, checked === true)}
                />
                <span className="flex-1">{factory.name}</span>
                {!factory.is_active && (
                  <span className="text-xs text-muted-foreground">(موقوف)</span>
                )}
              </label>
            ))}
          </div>
        )}

        {selected.length === 0 && factories.length > 0 && (
          <p className="text-sm text-warning-foreground">
            بدون اختيار أي مصنع، لن تصل إشعارات محادثات على هاتف هذا المدير إطلاقًا.
          </p>
        )}

        <DialogFooter>
          <Button variant="ghost" onClick={() => setOpen(false)} disabled={pending}>
            إلغاء
          </Button>
          <Button onClick={save} disabled={pending}>
            {pending && <Loader2 className="size-4 animate-spin" />}
            حفظ
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
