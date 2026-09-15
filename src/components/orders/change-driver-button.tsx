"use client";

import { useState, useTransition } from "react";
import { toast } from "sonner";
import { Loader2, UserCog } from "lucide-react";
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
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { reassignOrderDriverAction } from "@/lib/actions/orders";
import type { Profile } from "@/types/database";

/**
 * Lets the Owner/Moderator add or change who's responsible for an order at
 * any point before it's closed — on a brand-new order with nobody assigned
 * yet just as much as one already in progress (that's on top of, not
 * instead of, the suggest-then-approve flow in <DistributionPanel> for new
 * orders). Useful for assigning quickly, or when a driver calls in sick,
 * quits mid-route, etc.
 */
export function ChangeDriverButton({
  orderId,
  currentDriverId,
  drivers,
}: {
  orderId: string;
  currentDriverId: string | null;
  drivers: Profile[];
}) {
  const [open, setOpen] = useState(false);
  const [selected, setSelected] = useState<string>("");
  const [pending, startTransition] = useTransition();
  const hasDriver = Boolean(currentDriverId);

  const options = drivers.filter((d) => d.is_active && d.id !== currentDriverId);

  function submit() {
    if (!selected) return;
    startTransition(async () => {
      const res = await reassignOrderDriverAction(orderId, selected);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      toast.success(hasDriver ? "تم تغيير المندوب المسؤول" : "تم تعيين المندوب");
      setOpen(false);
      setSelected("");
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm" className="w-full">
          <UserCog className="size-4" />
          {hasDriver ? "تغيير المندوب" : "تعيين مندوب"}
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{hasDriver ? "تغيير المندوب المسؤول" : "تعيين مندوب للأوردر"}</DialogTitle>
          <DialogDescription>
            {hasDriver ? "سيتم إشعار المندوب الحالي والمندوب الجديد." : "سيتم إشعار المندوب المعيّن."}
          </DialogDescription>
        </DialogHeader>
        {options.length === 0 ? (
          <p className="text-sm text-muted-foreground">لا يوجد مندوبون نشطون آخرون متاحون حاليًا.</p>
        ) : (
          <Select value={selected} onValueChange={setSelected}>
            <SelectTrigger className="w-full">
              <SelectValue placeholder="اختر المندوب الجديد" />
            </SelectTrigger>
            <SelectContent>
              {options.map((d) => (
                <SelectItem key={d.id} value={d.id}>
                  {d.full_name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        )}
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>
            تراجع
          </Button>
          <Button onClick={submit} disabled={pending || !selected}>
            {pending && <Loader2 className="animate-spin" />}
            تأكيد
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
