"use client";

import { useMemo, useState, useTransition } from "react";
import { useRouter, useSearchParams, usePathname } from "next/navigation";
import Link from "next/link";
import { toast } from "sonner";
import { Loader2, CheckCheck, UserCog, PackageCheck, AlertTriangle, Factory as FactoryIcon } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Checkbox } from "@/components/ui/checkbox";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogHeader,
  DialogTitle,
} from "@/components/ui/dialog";
import { EmptyState } from "@/components/shared/empty-state";
import { OrderStatusBadge } from "@/components/orders/order-status-badge";
import {
  approveDistributionBulkAction,
  setOrderDistributionBulkAction,
  type BulkOutcome,
} from "@/lib/actions/orders";
import { formatDateTime } from "@/lib/domain/format";
import type { RegionGroup } from "@/lib/domain/distribution";
import type { OrderListRow } from "@/lib/data/orders";
import type { Profile, Factory } from "@/types/database";

/**
 * Bulk distribution board. Approving used to be one order at a time from
 * inside each order's own page; this shows everything still waiting, grouped
 * by area, with the suggested driver already filled in — tick what looks
 * right, or tick the whole area, and approve in one press.
 *
 * This is the one client boundary: the page fetches on the server and hands
 * groups down, and all selection state lives here so the rows and the action
 * bar can't disagree about what's selected.
 *
 * A Moderator can read the board but not act on it — approving and
 * reassigning have been Manager-only since migration 0024, and the database
 * enforces that independently, so hiding the controls is a courtesy rather
 * than the security boundary.
 */
export function DistributionBoard({
  groups,
  unallocated,
  drivers,
  factories,
  canApprove,
  activeFactoryId,
}: {
  groups: RegionGroup[];
  unallocated: OrderListRow[];
  drivers: Profile[];
  factories: Factory[];
  canApprove: boolean;
  activeFactoryId: string | null;
}) {
  const router = useRouter();
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const [pending, startTransition] = useTransition();
  const [selected, setSelected] = useState<Set<string>>(new Set());
  const [moveDriverId, setMoveDriverId] = useState<string>("");
  const [failures, setFailures] = useState<BulkOutcome[] | null>(null);

  // Changing the factory filter re-renders the server component and hands
  // down different groups — anything selected from the previous filter is no
  // longer on screen, so keeping it selected would mean approving orders the
  // manager can't see. Same render-time prop-change pattern TeamManager uses.
  const [prevGroups, setPrevGroups] = useState(groups);
  if (groups !== prevGroups) {
    setPrevGroups(groups);
    setSelected(new Set());
  }

  const allIds = useMemo(() => groups.flatMap((g) => g.orders.map((o) => o.id)), [groups]);
  const totalPending = allIds.length;

  function toggleOne(id: string) {
    setSelected((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });
  }

  function toggleGroup(group: RegionGroup) {
    const ids = group.orders.map((o) => o.id);
    const allOn = ids.every((id) => selected.has(id));
    setSelected((prev) => {
      const next = new Set(prev);
      for (const id of ids) {
        if (allOn) next.delete(id);
        else next.add(id);
      }
      return next;
    });
  }

  function handleResult(
    res: Awaited<ReturnType<typeof approveDistributionBulkAction>>,
    verb: string,
  ) {
    if (!res.ok) {
      toast.error(res.error);
      return;
    }
    const { approved, failures: failed } = res.data;
    if (approved > 0) toast.success(`${verb} ${approved} أوردر`);
    if (failed.length > 0) {
      setFailures(failed);
    } else {
      setSelected(new Set());
    }
    router.refresh();
  }

  function approveSelected(ids: string[]) {
    startTransition(async () => {
      handleResult(await approveDistributionBulkAction(ids), "تم اعتماد");
    });
  }

  function moveSelected() {
    if (!moveDriverId) {
      toast.error("اختر المندوب أولًا");
      return;
    }
    startTransition(async () => {
      handleResult(await setOrderDistributionBulkAction([...selected], moveDriverId), "تم نقل");
      setMoveDriverId("");
    });
  }

  function setFactoryFilter(value: string) {
    const params = new URLSearchParams(searchParams.toString());
    if (value === "all") params.delete("factory");
    else params.set("factory", value);
    const qs = params.toString();
    router.push(qs ? `${pathname}?${qs}` : pathname);
  }

  return (
    <div className="space-y-4 pb-24">
      <div className="flex flex-wrap items-center justify-between gap-2">
        <div>
          <h1 className="text-xl font-bold">توزيع الأوردرات</h1>
          <p className="text-sm text-muted-foreground">
            {totalPending > 0
              ? `${totalPending} أوردر بانتظار اعتماد التوزيع`
              : "لا يوجد أوردرات بانتظار الاعتماد"}
          </p>
        </div>
        <div className="flex items-center gap-2">
          <FactoryIcon className="size-4 text-muted-foreground" />
          <Select value={activeFactoryId ?? "all"} onValueChange={setFactoryFilter}>
            <SelectTrigger className="w-[190px]" aria-label="تصفية حسب المصنع">
              <SelectValue placeholder="كل المصانع" />
            </SelectTrigger>
            <SelectContent>
              <SelectItem value="all">كل المصانع</SelectItem>
              {factories.map((f) => (
                <SelectItem key={f.id} value={f.id}>
                  {f.name}
                </SelectItem>
              ))}
            </SelectContent>
          </Select>
        </div>
      </div>

      {unallocated.length > 0 && (
        <Card className="border-warning/50">
          <CardHeader>
            <CardTitle className="flex items-center gap-2 text-base">
              <AlertTriangle className="size-4 text-warning" />
              بحاجة لتعيين مندوب ({unallocated.length})
            </CardTitle>
          </CardHeader>
          <CardContent className="space-y-2">
            {unallocated.map((order) => (
              <Link
                key={order.id}
                href={`/moderator/orders/${order.id}`}
                className="flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg border bg-warning/5 p-3 text-sm transition-colors hover:bg-warning/10"
              >
                <span className="font-medium" dir="ltr">
                  {order.order_number}
                </span>
                <span className="text-muted-foreground">{order.customer_name}</span>
                <Badge variant="outline">{order.region?.name ?? "بدون منطقة"}</Badge>
                <OrderStatusBadge status={order.status} />
                {order.needs_allocation_reason && (
                  <span className="text-xs text-warning">{order.needs_allocation_reason}</span>
                )}
              </Link>
            ))}
          </CardContent>
        </Card>
      )}

      {groups.length === 0 ? (
        <Card>
          <CardContent className="p-0">
            <EmptyState icon={PackageCheck} title="لا يوجد أوردرات بانتظار اعتماد التوزيع" />
          </CardContent>
        </Card>
      ) : (
        groups.map((group) => {
          const ids = group.orders.map((o) => o.id);
          const selectedHere = ids.filter((id) => selected.has(id)).length;
          const allOn = selectedHere === ids.length && ids.length > 0;

          return (
            <Card key={group.regionId ?? "__none__"}>
              <CardHeader className="flex-row items-center justify-between gap-2 space-y-0">
                <CardTitle className="flex items-center gap-2 text-base">
                  {canApprove && (
                    <Checkbox
                      checked={allOn}
                      onCheckedChange={() => toggleGroup(group)}
                      aria-label={`تحديد كل أوردرات ${group.regionName}`}
                    />
                  )}
                  {group.regionName}
                  <Badge variant="outline">{group.orders.length}</Badge>
                  {selectedHere > 0 && <Badge variant="default">محدد {selectedHere}</Badge>}
                </CardTitle>
                {canApprove && (
                  <Button size="sm" variant="outline" disabled={pending} onClick={() => approveSelected(ids)}>
                    {pending ? <Loader2 className="animate-spin" /> : <CheckCheck />}
                    اعتماد كل المنطقة
                  </Button>
                )}
              </CardHeader>
              <CardContent className="space-y-2">
                {group.orders.map((order) => (
                  <div
                    key={order.id}
                    className="flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg border p-3 text-sm"
                  >
                    {canApprove && (
                      <Checkbox
                        checked={selected.has(order.id)}
                        onCheckedChange={() => toggleOne(order.id)}
                        aria-label={`تحديد الأوردر ${order.order_number}`}
                      />
                    )}
                    <Link
                      href={`/moderator/orders/${order.id}`}
                      className="font-medium hover:underline"
                      dir="ltr"
                    >
                      {order.order_number}
                    </Link>
                    <span className="text-muted-foreground">{order.customer_name}</span>
                    <span className="flex items-center gap-1">
                      <UserCog className="size-3.5 text-muted-foreground" />
                      {order.assigned_driver_name ?? (
                        <span className="text-warning">لا يوجد مندوب مقترح</span>
                      )}
                    </span>
                    <span className="ms-auto text-xs text-muted-foreground">
                      {formatDateTime(order.created_at)}
                    </span>
                  </div>
                ))}
              </CardContent>
            </Card>
          );
        })
      )}

      {canApprove && selected.size > 0 && (
        <div className="fixed inset-x-0 bottom-0 z-30 border-t bg-background/95 p-3 shadow-lg backdrop-blur">
          <div className="mx-auto flex max-w-5xl flex-wrap items-center gap-2">
            <Badge variant="default" className="text-sm">
              محدد {selected.size}
            </Badge>
            <Button size="sm" variant="ghost" onClick={() => setSelected(new Set())} disabled={pending}>
              إلغاء التحديد
            </Button>
            <div className="ms-auto flex flex-wrap items-center gap-2">
              <Select value={moveDriverId} onValueChange={setMoveDriverId}>
                <SelectTrigger className="w-[180px]" aria-label="نقل إلى مندوب">
                  <SelectValue placeholder="نقل إلى مندوب" />
                </SelectTrigger>
                <SelectContent>
                  {drivers.map((d) => (
                    <SelectItem key={d.id} value={d.id}>
                      {d.full_name}
                    </SelectItem>
                  ))}
                </SelectContent>
              </Select>
              <Button size="sm" variant="outline" onClick={moveSelected} disabled={pending || !moveDriverId}>
                {pending ? <Loader2 className="animate-spin" /> : <UserCog />}
                نقل
              </Button>
              <Button size="sm" onClick={() => approveSelected([...selected])} disabled={pending}>
                {pending ? <Loader2 className="animate-spin" /> : <CheckCheck />}
                اعتماد التوزيع
              </Button>
            </div>
          </div>
        </div>
      )}

      {/* Partial failures get their own dialog rather than a toast: the whole
          point of the bulk RPC is that the rest still went through, so the
          manager needs to see exactly which ones didn't and why. */}
      <Dialog open={failures !== null} onOpenChange={(open) => !open && setFailures(null)}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>بعض الأوردرات لم تتم</DialogTitle>
            <DialogDescription>
              باقي الأوردرات تمت بنجاح. دي اللي محتاجة مراجعة:
            </DialogDescription>
          </DialogHeader>
          <div className="max-h-[50vh] space-y-2 overflow-y-auto">
            {(failures ?? []).map((f) => (
              <div key={f.order_id} className="rounded-lg border p-3 text-sm">
                <p className="font-medium" dir="ltr">
                  {f.order_number ?? f.order_id}
                </p>
                <p className="text-muted-foreground">{f.error}</p>
              </div>
            ))}
          </div>
        </DialogContent>
      </Dialog>
    </div>
  );
}
