"use client";

import { AlertTriangle, History, UserCheck } from "lucide-react";
import {
  AlertDialog,
  AlertDialogAction,
  AlertDialogCancel,
  AlertDialogContent,
  AlertDialogDescription,
  AlertDialogFooter,
  AlertDialogHeader,
  AlertDialogTitle,
} from "@/components/ui/alert-dialog";
import type { RepeatCustomerNotice } from "@/lib/domain/customer-history";

/**
 * Shown between pressing "create" and the order actually being created, when
 * the customer's phone number has ordered before.
 *
 * An AlertDialog rather than a toast: this asks a question and the answer
 * changes what happens, so it has to be acknowledged. A toast would be
 * dismissed by the same press that created the order.
 *
 * It confirms rather than blocks — a repeat customer is normal and usually
 * good news, so "متابعة" is the primary button and nothing here can stop a
 * real order being taken. The two cases that deserve a second look (an order
 * already in flight, and a name that does not match the one on file) are
 * called out separately above the buttons rather than being left for the
 * reader to work out from the counts.
 */
export function RepeatCustomerDialog({
  notice,
  open,
  onCancel,
  onConfirm,
}: {
  notice: RepeatCustomerNotice | null;
  open: boolean;
  onCancel: () => void;
  onConfirm: () => void;
}) {
  if (!notice?.isRepeat) return null;

  const hasFlag = Boolean(notice.openWarning || notice.nameMismatch);

  return (
    <AlertDialog open={open} onOpenChange={(next) => !next && onCancel()}>
      <AlertDialogContent>
        <AlertDialogHeader>
          <AlertDialogTitle className="flex items-center gap-2">
            {hasFlag ? (
              <AlertTriangle className="size-5 shrink-0 text-warning" />
            ) : (
              <UserCheck className="size-5 shrink-0 text-muted-foreground" />
            )}
            عميل سجّل أوردرات قبل كذا
          </AlertDialogTitle>
          <AlertDialogDescription asChild>
            <div className="space-y-3 text-start">
              <p className="text-base font-medium text-foreground">{notice.title}</p>

              <div className="flex items-baseline justify-center gap-2 rounded-lg border bg-muted/40 p-3">
                <span className="text-sm text-muted-foreground">رقم الأوردر لهذا العميل</span>
                <span className="text-3xl font-bold tabular-nums">{notice.orderIndex}</span>
              </div>

              {notice.breakdown && (
                <p className="flex items-center gap-1.5 text-sm">
                  <History className="size-4 shrink-0 text-muted-foreground" />
                  <span>{notice.breakdown}</span>
                </p>
              )}

              {notice.lastOrderLine && (
                <p className="text-sm text-muted-foreground">{notice.lastOrderLine}</p>
              )}

              {notice.nameMismatch && (
                <p className="rounded-md border border-warning/40 bg-warning/10 p-2 text-sm font-medium text-foreground">
                  {notice.nameMismatch}
                </p>
              )}

              {notice.openWarning && (
                <p className="rounded-md border border-warning/40 bg-warning/10 p-2 text-sm font-medium text-foreground">
                  {notice.openWarning}
                </p>
              )}
            </div>
          </AlertDialogDescription>
        </AlertDialogHeader>
        <AlertDialogFooter>
          <AlertDialogCancel onClick={onCancel}>رجوع للتعديل</AlertDialogCancel>
          <AlertDialogAction onClick={onConfirm}>متابعة وإنشاء الأوردر</AlertDialogAction>
        </AlertDialogFooter>
      </AlertDialogContent>
    </AlertDialog>
  );
}
