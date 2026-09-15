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
 * Lets the Owner/Moderator change who's responsible for an order at any
 * point before it's closed — not just before distribution is approved
 * (that earlier stage is handled by <DistributionPanel>). Useful when a
 * driver calls in sick, quits mid-route, etc.
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

  const options = drivers.filter((d) => d.is_active && d.id !== currentDriverId);

  function submit() {
    if (!selected) return;
    startTransition(async () => {
      const res = await reassignOrderDriverAction(orderId, selected);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      toast.success("تم تغيير المندوب المسؤول");
      setOpen(false);
      setSelected("");
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm" className="w-full">
          <UserCog className="size-4" />
          تغيير المندوب
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>تغيير المندوب المسؤول</DialogTitle>
          <DialogDescription>سيتم إشعار المندوب الحالي (إن وجد) والمندوب الجديد.</DialogDescription>
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
