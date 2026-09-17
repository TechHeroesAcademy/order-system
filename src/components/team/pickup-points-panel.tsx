"use client";

import { useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { Loader2, MapPin, Plus, Warehouse } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import { EmptyState } from "@/components/shared/empty-state";
import { RegionTagsInput } from "./region-tags-input";
import {
  createPickupPointAction,
  updatePickupPointAction,
  setPickupPointActiveAction,
  setPickupPointRegionsAction,
} from "@/lib/actions/admin";
import { pickupPointSchema } from "@/lib/domain/validators";
import { mapsUrlFor } from "@/lib/domain/maps";
import type { PickupPoint, Region } from "@/types/database";

/**
 * "نقاط التجميع" tab — where Owner/Moderator set up local drop-off points
 * for drivers (EL REWAD only runs two factories, Cairo and Alexandria, so
 * drivers need somewhere closer to hand off what they've collected — see
 * the migration 0026 header comment). A pickup point is purely a
 * destination reference, same as a factory's address/map link; getting the
 * pieces from there to the actual factory isn't tracked order-by-order.
 */
export function PickupPointsPanel({
  pickupPoints,
  regions,
  pickupPointRegionsMap,
}: {
  pickupPoints: PickupPoint[];
  regions: Region[];
  pickupPointRegionsMap: Record<string, string[]>;
}) {
  const [points, setPoints] = useState(pickupPoints);
  const [regionsByPoint, setRegionsByPoint] = useState(pickupPointRegionsMap);

  // Same render-time "adjust state when a prop changes" pattern used
  // elsewhere in TeamManager — router.refresh() after a typed region name
  // creates a brand-new region needs to flow back into this local state.
  const [prevPoints, setPrevPoints] = useState(pickupPoints);
  if (pickupPoints !== prevPoints) {
    setPrevPoints(pickupPoints);
    setPoints(pickupPoints);
  }
  const [prevMap, setPrevMap] = useState(pickupPointRegionsMap);
  if (pickupPointRegionsMap !== prevMap) {
    setPrevMap(pickupPointRegionsMap);
    setRegionsByPoint(pickupPointRegionsMap);
  }

  function updatePoint(id: string, patch: Partial<PickupPoint>) {
    setPoints((prev) => prev.map((p) => (p.id === id ? { ...p, ...patch } : p)));
  }

  return (
    <Card>
      <CardHeader className="flex-row items-center justify-between space-y-0">
        <CardTitle className="text-base">نقاط التجميع ({points.length})</CardTitle>
        <AddPickupPointDialog
          regions={regions}
          onCreated={(point) => setPoints((prev) => [...prev, point])}
        />
      </CardHeader>
      <CardContent className="p-0">
        {points.length === 0 ? (
          <EmptyState
            icon={Warehouse}
            title="لا توجد نقاط تجميع بعد"
            description="أضف نقطة تجميع ليعرف المندوبون أين يسلّمون الأواني المُجمّعة بدلًا من التوجه للمصنع مباشرة."
          />
        ) : (
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>الاسم</TableHead>
                <TableHead>العنوان</TableHead>
                <TableHead>المناطق</TableHead>
                <TableHead>الحالة</TableHead>
                <TableHead />
              </TableRow>
            </TableHeader>
            <TableBody>
              {points.map((point) => (
                <PickupPointRow
                  key={point.id}
                  point={point}
                  regions={regions}
                  assignedIds={regionsByPoint[point.id] ?? []}
                  onUpdated={(patch) => updatePoint(point.id, patch)}
                />
              ))}
            </TableBody>
          </Table>
        )}
      </CardContent>
    </Card>
  );
}

function PickupPointRow({
  point,
  regions,
  assignedIds,
  onUpdated,
}: {
  point: PickupPoint;
  regions: Region[];
  assignedIds: string[];
  onUpdated: (patch: Partial<PickupPoint>) => void;
}) {
  const [togglePending, startToggle] = useTransition();
  const mapsHref = mapsUrlFor(point);

  function toggleActive() {
    startToggle(async () => {
      const res = await setPickupPointActiveAction(point.id, !point.is_active);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      onUpdated({ is_active: !point.is_active });
      toast.success(point.is_active ? "تم إيقاف نقطة التجميع" : "تم تفعيل نقطة التجميع");
    });
  }

  return (
    <TableRow>
      <TableCell className="font-medium">
        <EditPickupPointDialog point={point} onUpdated={onUpdated} />
      </TableCell>
      <TableCell className="text-muted-foreground">
        {mapsHref ? (
          <a
            href={mapsHref}
            target="_blank"
            rel="noopener noreferrer"
            className="inline-flex items-center gap-1 hover:underline"
          >
            <MapPin className="size-3.5" />
            {point.address ?? "فتح على الخريطة"}
          </a>
        ) : (
          point.address ?? "—"
        )}
      </TableCell>
      <TableCell>
        <PickupPointRegionsCell pointId={point.id} regions={regions} assignedIds={assignedIds} />
      </TableCell>
      <TableCell>
        {point.is_active ? <Badge variant="success">نشطة</Badge> : <Badge variant="destructive">موقوفة</Badge>}
      </TableCell>
      <TableCell>
        <Button variant="outline" size="sm" onClick={toggleActive} disabled={togglePending}>
          {togglePending && <Loader2 className="animate-spin" />}
          {point.is_active ? "إيقاف" : "تفعيل"}
        </Button>
      </TableCell>
    </TableRow>
  );
}

function PickupPointRegionsCell({
  pointId,
  regions,
  assignedIds,
}: {
  pointId: string;
  regions: Region[];
  assignedIds: string[];
}) {
  const [open, setOpen] = useState(false);
  const assignedNames = regions.filter((r) => assignedIds.includes(r.id)).map((r) => r.name);
  const [names, setNames] = useState<string[]>(assignedNames);
  const [pending, startTransition] = useTransition();
  const router = useRouter();

  function save() {
    startTransition(async () => {
      const res = await setPickupPointRegionsAction(pointId, { region_names: names });
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      toast.success("تم تحديث مناطق نقطة التجميع");
      setOpen(false);
      router.refresh();
    });
  }

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        setOpen(next);
        if (next) setNames(assignedNames);
      }}
    >
      <DialogTrigger asChild>
        <button className="flex items-center gap-1 text-start text-sm hover:underline">
          <MapPin className="size-3.5 text-muted-foreground" />
          {assignedNames.length > 0 ? assignedNames.join("، ") : "تحديد المناطق"}
        </button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>مناطق تغطية نقطة التجميع</DialogTitle>
          <DialogDescription>
            المندوبون في هذه المناطق يعرفون أن هذه أقرب نقطة تجميع لهم.
          </DialogDescription>
        </DialogHeader>
        <RegionTagsInput value={names} onChange={setNames} regions={regions} />
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

function AddPickupPointDialog({
  regions,
  onCreated,
}: {
  regions: Region[];
  onCreated: (point: PickupPoint) => void;
}) {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState("");
  const [address, setAddress] = useState("");
  const [mapsUrl, setMapsUrl] = useState("");
  const [regionNames, setRegionNames] = useState<string[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();
  const router = useRouter();

  function reset() {
    setName("");
    setAddress("");
    setMapsUrl("");
    setRegionNames([]);
    setError(null);
  }

  function submit() {
    const parsed = pickupPointSchema.safeParse({
      name,
      address: address || undefined,
      maps_url: mapsUrl || undefined,
      region_names: regionNames,
    });
    if (!parsed.success) {
      setError(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");
      return;
    }
    setError(null);
    startTransition(async () => {
      const res = await createPickupPointAction(parsed.data);
      if (!res.ok) {
        setError(res.error);
        return;
      }
      onCreated({
        id: res.data.id,
        name: parsed.data.name,
        address: parsed.data.address?.trim() || null,
        lat: null,
        lng: null,
        maps_url: parsed.data.maps_url?.trim() || null,
        is_active: true,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      });
      toast.success(`تمت إضافة نقطة التجميع "${parsed.data.name}"`);
      reset();
      setOpen(false);
      if (parsed.data.region_names.length > 0) router.refresh();
    });
  }

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        setOpen(next);
        if (!next) reset();
      }}
    >
      <DialogTrigger asChild>
        <Button>
          <Plus />
          نقطة تجميع جديدة
        </Button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>إضافة نقطة تجميع</DialogTitle>
          <DialogDescription>مكان يتوجه إليه المندوبون لتسليم الأواني المُجمّعة بدل المصنع مباشرة.</DialogDescription>
        </DialogHeader>
        <div className="space-y-3">
          <div className="space-y-1.5">
            <Label htmlFor="pp-name">اسم نقطة التجميع</Label>
            <Input
              id="pp-name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="مثال: نقطة تجميع المعادي"
            />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="pp-address">العنوان (اختياري)</Label>
            <Input id="pp-address" value={address} onChange={(e) => setAddress(e.target.value)} />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="pp-maps-url">رابط خرائط جوجل (اختياري)</Label>
            <Input
              id="pp-maps-url"
              dir="ltr"
              value={mapsUrl}
              onChange={(e) => setMapsUrl(e.target.value)}
              placeholder="https://www.google.com/maps/place/..."
            />
          </div>
          <div className="space-y-1.5">
            <Label>المناطق التي تخدمها</Label>
            <RegionTagsInput value={regionNames} onChange={setRegionNames} regions={regions} />
          </div>
          {error && <p className="text-sm text-destructive">{error}</p>}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>
            تراجع
          </Button>
          <Button onClick={submit} disabled={pending}>
            {pending && <Loader2 className="animate-spin" />}
            إضافة
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function EditPickupPointDialog({
  point,
  onUpdated,
}: {
  point: PickupPoint;
  onUpdated: (patch: Partial<PickupPoint>) => void;
}) {
  const [open, setOpen] = useState(false);
  const [name, setName] = useState(point.name);
  const [address, setAddress] = useState(point.address ?? "");
  const [mapsUrl, setMapsUrl] = useState(point.maps_url ?? "");
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  function submit() {
    const parsed = pickupPointSchema.omit({ region_names: true }).safeParse({
      name,
      address: address || undefined,
      maps_url: mapsUrl || undefined,
    });
    if (!parsed.success) {
      setError(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");
      return;
    }
    setError(null);
    startTransition(async () => {
      const res = await updatePickupPointAction(point.id, parsed.data);
      if (!res.ok) {
        setError(res.error);
        return;
      }
      onUpdated({
        name: parsed.data.name,
        address: parsed.data.address?.trim() || null,
        maps_url: parsed.data.maps_url?.trim() || null,
      });
      toast.success("تم تحديث نقطة التجميع");
      setOpen(false);
    });
  }

  return (
    <Dialog
      open={open}
      onOpenChange={(next) => {
        setOpen(next);
        if (next) {
          setName(point.name);
          setAddress(point.address ?? "");
          setMapsUrl(point.maps_url ?? "");
          setError(null);
        }
      }}
    >
      <DialogTrigger asChild>
        <button className="text-start hover:underline">{point.name}</button>
      </DialogTrigger>
      <DialogContent>
        <DialogHeader>
          <DialogTitle>تعديل نقطة التجميع</DialogTitle>
        </DialogHeader>
        <div className="space-y-3">
          <div className="space-y-1.5">
            <Label htmlFor="pp-edit-name">اسم نقطة التجميع</Label>
            <Input id="pp-edit-name" value={name} onChange={(e) => setName(e.target.value)} />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="pp-edit-address">العنوان (اختياري)</Label>
            <Input id="pp-edit-address" value={address} onChange={(e) => setAddress(e.target.value)} />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="pp-edit-maps-url">رابط خرائط جوجل (اختياري)</Label>
            <Input id="pp-edit-maps-url" dir="ltr" value={mapsUrl} onChange={(e) => setMapsUrl(e.target.value)} />
          </div>
          {error && <p className="text-sm text-destructive">{error}</p>}
        </div>
        <DialogFooter>
          <Button variant="outline" onClick={() => setOpen(false)} disabled={pending}>
            تراجع
          </Button>
          <Button onClick={submit} disabled={pending}>
            {pending && <Loader2 className="animate-spin" />}
            حفظ
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
