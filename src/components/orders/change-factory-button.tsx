"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { Loader2, Factory as FactoryIcon } from "lucide-react";
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
import { reassignOrderFactoryAction } from "@/lib/actions/orders";
import type { Factory } from "@/types/database";

/**
 * Lets the Owner/Moderator route an order to a different factory at any
 * point before it's closed — same shape as <ChangeDriverButton>, on top of
 * (not instead of) picking a factory at creation. The location shown to the
 * assigned driver updates the moment this commits, since their page always
 * reads assigned_factory_id fresh (see reassign_order_factory, migration 0018).
 */
export function ChangeFactoryButton({
  orderId,
  currentFactoryId,
  factories,
  compact = false,
}: {
  orderId: string;
  currentFactoryId: string | null;
  factories: Factory[];
  /** Icon-only trigger for tight spaces (an orders-table row) instead of the full-width labeled button. */
  compact?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const [selected, setSelected] = useState<string>("");
  const [pending, startTransition] = useTransition();
  const router = useRouter();
  const hasFactory = Boolean(currentFactoryId);

  const options = factories.filter((f) => f.is_active && f.id !== currentFactoryId);

  function submit() {
    if (!selected) return;
    startTransition(async () => {
      const res = await reassignOrderFactoryAction(orderId, selected);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      toast.success(hasFactory ? "تم تغيير المصنع" : "تم تحديد المصنع");
      setOpen(false);
      setSelected("");
      router.refresh();
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        {compact ? (
          <Button variant="ghost" size="icon" title={hasFactory ? "تغيير المصنع" : "تحديد المصنع"}>
            <FactoryIcon className="size-4" />
          </Button>
        ) : (
          <Button variant="outline" size="sm" className="w-full">
            <FactoryIcon className="size-4" />
            {hasFactory ? "تغيير المصنع" : "تحديد المصنع"}
          </Button>
        )}
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>{hasFactory ? "تغيير المصنع المخصص" : "تحديد مصنع للأوردر"}</DialogTitle>
          <DialogDescription>
            {hasFactory
              ? "سيتم إشعار المندوب المسؤول بالموقع الجديد."
              : "سيصبح الأوردر مرئيًا لهذا المصنع فقط بدلًا من كل المصانع."}
          </DialogDescription>
        </DialogHeader>
        {options.length === 0 ? (
          <p className="text-sm text-muted-foreground">لا يوجد مصانع نشطة أخرى متاحة حاليًا.</p>
        ) : (
          <Select value={selected} onValueChange={setSelected}>
            <SelectTrigger className="w-full">
              <SelectValue placeholder="اختر المصنع الجديد" />
            </SelectTrigger>
            <SelectContent>
              {options.map((f) => (
                <SelectItem key={f.id} value={f.id}>
                  {f.name}
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
