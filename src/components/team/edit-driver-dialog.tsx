"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { Loader2, Pencil } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { RegionTagsInput } from "./region-tags-input";
import { updateStaffProfileAction, setDriverRegionsAction } from "@/lib/actions/admin";
import type { Region } from "@/types/database";

/**
 * Editing a driver — name and the areas they cover, in one place, which is
 * how a manager thinks about it. Manager-only; the two RPCs behind it refuse
 * anyone else regardless of what this renders.
 *
 * The phone number is shown but not editable: it's how the driver signs in,
 * so changing it changes their login and is a bigger job than a detail edit.
 *
 * Correcting the name also corrects it on their past orders — those carry a
 * snapshot of the name (migration 0032), and fixing it in one place while
 * leaving it wrong everywhere it's actually read wouldn't be much of a fix.
 */
export function EditDriverButton({
  driverId,
  fullName,
  phone,
  regions,
  assignedRegionNames,
  onSaved,
}: {
  driverId: string;
  fullName: string;
  phone: string | null;
  regions: Region[];
  assignedRegionNames: string[];
  onSaved: (fullName: string) => void;
}) {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState(fullName);
  const [names, setNames] = useState<string[]>(assignedRegionNames);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const router = useRouter();

  function reset(nextOpen: boolean) {
    setOpen(nextOpen);
    if (nextOpen) {
      setName(fullName);
      setNames(assignedRegionNames);
      setError(null);
    }
  }

  function save() {
    const trimmed = name.trim();
    if (trimmed.length < 2) {
      setError("الاسم قصير جدًا");
      return;
    }
    setError(null);

    startTransition(async () => {
      // Only touch the name if it actually changed, so saving an unchanged
      // dialog doesn't rewrite every order this driver ever had.
      if (trimmed !== fullName) {
        const res = await updateStaffProfileAction(driverId, trimmed);
        if (!res.ok) {
          setError(res.error);
          return;
        }
      }

      const regionsChanged =
        names.length !== assignedRegionNames.length ||
        names.some((n) => !assignedRegionNames.includes(n));

      if (regionsChanged) {
        const res = await setDriverRegionsAction(driverId, names);
        if (!res.ok) {
          setError(res.error);
          return;
        }
      }

      onSaved(trimmed);
      setOpen(false);
      toast.success("تم تحديث بيانات المندوب");
      // A typed area name may have created a brand-new region — refresh so
      // the list and this driver's areas stay in step with it.
      router.refresh();
    });
  }

  return (
    <Dialog open={open} onOpenChange={reset}>
      <DialogTrigger asChild>
        <Button size="sm" variant="outline" title="تعديل بيانات المندوب">
          <Pencil className="size-4" />
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>تعديل بيانات المندوب</DialogTitle>
          <DialogDescription>
            تعديل الاسم هيغيّره كمان على الأوردرات السابقة الخاصة بالمندوب.
          </DialogDescription>
        </DialogHeader>

        <div className="space-y-4">
          <div className="space-y-1.5">
            <Label htmlFor={`driver-name-${driverId}`}>الاسم</Label>
            <Input
              id={`driver-name-${driverId}`}
              value={name}
              onChange={(e) => setName(e.target.value)}
            />
          </div>

          <div className="space-y-1.5">
            <Label>رقم الهاتف</Label>
            <Input value={phone ?? "—"} dir="ltr" disabled readOnly />
            <p className="text-xs text-muted-foreground">
              رقم الهاتف هو رقم تسجيل الدخول ولا يمكن تغييره من هنا.
            </p>
          </div>

          <div className="space-y-1.5">
            <Label>مناطق التغطية</Label>
            <RegionTagsInput value={names} onChange={setNames} regions={regions} />
            <p className="text-xs text-muted-foreground">
              المناطق دي بتحدد إمتى يترشّح المندوب تلقائيًا لأوردر جديد.
            </p>
          </div>

          {error && <p className="text-sm text-destructive">{error}</p>}
        </div>

        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>
            تراجع
          </Button>
          <Button onClick={save} disabled={pending}>
            {pending && <Loader2 className="animate-spin" />}
            حفظ
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
