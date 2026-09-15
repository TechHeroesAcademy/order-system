"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { Loader2, Ban } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { cancelOrderAction } from "@/lib/actions/orders";
import { cancelOrderSchema } from "@/lib/domain/validators";

export function CancelOrderButton({ orderId, compact = false }: { orderId: string; compact?: boolean }) {
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const router = useRouter();

  function handleConfirm() {
    const parsed = cancelOrderSchema.safeParse({ reason });
    if (!parsed.success) {
      setError(parsed.error.issues[0]?.message ?? "أدخل سبب الإلغاء");
      return;
    }
    setError(null);
    startTransition(async () => {
      const res = await cancelOrderAction(orderId, parsed.data.reason);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      toast.success("تم إلغاء الأوردر");
      setOpen(false);
      setReason("");
      router.refresh();
    });
  }

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        {compact ? (
          <Button variant="ghost" size="icon" title="إلغاء الأوردر" className="text-destructive hover:text-destructive">
            <Ban className="size-4" />
          </Button>
        ) : (
          <Button variant="destructive" className="w-full">
            <Ban />
            إلغاء الأوردر
          </Button>
        )}
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>إلغاء الأوردر</DialogTitle>
          <DialogDescription>اكتب سبب الإلغاء. لا يمكن التراجع عن هذا الإجراء.</DialogDescription>
        </DialogHeader>
        <Textarea
          value={reason}
          onChange={(e) => setReason(e.target.value)}
          placeholder="سبب الإلغاء..."
          rows={3}
        />
        {error && <p className="text-sm text-destructive">{error}</p>}
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>
            تراجع
          </Button>
          <Button variant="destructive" onClick={handleConfirm} disabled={pending}>
            {pending && <Loader2 className="animate-spin" />}
            تأكيد الإلغاء
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
