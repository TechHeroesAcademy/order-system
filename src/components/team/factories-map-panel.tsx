"use client";

import { useMemo, useState, useTransition } from "react";
import dynamic from "next/dynamic";
import { toast } from "sonner";
import { Loader2, Factory, MapPin, Map as MapIcon, X } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { EmptyState } from "@/components/shared/empty-state";
import { updateStaffLocationAction } from "@/lib/actions/admin";
import { updateStaffLocationSchema } from "@/lib/domain/validators";
import { mapsUrlFor } from "@/lib/domain/maps";
import { ToggleActiveButton, ResetPasswordButton } from "./staff-actions";
import type { Profile } from "@/types/database";
import type { FactoryPin } from "@/components/maps/factories-overview-map";

// Leaflet touches `window` at render time, so this loads client-only —
// dynamic(..., { ssr: false }) is how a "use client" component still opts a
// child out of any server render pass.
const FactoriesMap = dynamic(
  () => import("@/components/maps/factories-overview-map").then((m) => m.FactoriesMap),
  { ssr: false, loading: () => <div className="h-[360px] animate-pulse rounded-lg border bg-muted" /> },
);

/**
 * Factories tab of Team management — one general map of every factory pin,
 * plus (select a marker or a table row) an inline edit card for that
 * factory's address/Maps-link/pin, and the factories table itself. Replaces
 * the old design of one map here plus a second small map inside each
 * factory's own edit dialog — now there's exactly one map, and clicking a
 * pin (or a table row) is how you edit that factory.
 */
export function FactoriesMapPanel({
  factories,
  onSaved,
  onToggled,
}: {
  factories: Profile[];
  onSaved: (
    id: string,
    next: { address: string | null; lat: number | null; lng: number | null; maps_url: string | null },
  ) => void;
  onToggled: (id: string, isActive: boolean) => void;
}) {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [address, setAddress] = useState("");
  const [mapsUrlValue, setMapsUrlValue] = useState("");
  const [pin, setPin] = useState<{ lat: number; lng: number } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  const selected = factories.find((f) => f.id === selectedId) ?? null;

  const pins: FactoryPin[] = useMemo(
    () =>
      factories
        .filter((f): f is Profile & { lat: number; lng: number } => f.lat != null && f.lng != null)
        .map((f) => ({ id: f.id, full_name: f.full_name, address: f.address, lat: f.lat, lng: f.lng })),
    [factories],
  );

  function select(factory: Profile) {
    setSelectedId(factory.id);
    setAddress(factory.address ?? "");
    setMapsUrlValue(factory.maps_url ?? "");
    setPin(factory.lat != null && factory.lng != null ? { lat: factory.lat, lng: factory.lng } : null);
    setError(null);
  }

  function clearSelection() {
    setSelectedId(null);
    setError(null);
  }

  function save() {
    if (!selected) return;
    const parsed = updateStaffLocationSchema.safeParse({
      address,
      maps_url: mapsUrlValue,
      lat: pin?.lat ?? null,
      lng: pin?.lng ?? null,
    });
    if (!parsed.success) {
      setError(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");
      return;
    }
    setError(null);
    startTransition(async () => {
      const res = await updateStaffLocationAction(selected.id, parsed.data);
      if (!res.ok) {
        setError(res.error);
        return;
      }
      onSaved(selected.id, {
        address: parsed.data.address?.trim() || null,
        lat: parsed.data.lat,
        lng: parsed.data.lng,
        maps_url: parsed.data.maps_url?.trim() || null,
      });
      toast.success("تم تحديث موقع المصنع");
    });
  }

  return (
    <div className="space-y-4">
      <Card>
        <CardHeader>
          <CardTitle className="flex items-center gap-2 text-base">
            <MapIcon className="size-4" />
            خريطة المصانع ({pins.length})
          </CardTitle>
        </CardHeader>
        <CardContent className="space-y-3">
          <p className="text-xs text-muted-foreground">
            انقر على أي علامة لتعديل بيانات المصنع، أو اختره من الجدول أدناه. إن لم يكن للمصنع المختار موقع محدد
            بعد، انقر في أي مكان على الخريطة لتحديده.
          </p>
          <FactoriesMap
            factories={pins}
            selectedId={selectedId}
            selectedPin={pin}
            onSelectPin={(id) => {
              const factory = factories.find((f) => f.id === id);
              if (factory) select(factory);
            }}
            onPinChange={(lat, lng) => setPin({ lat, lng })}
          />

          {selected && (
            <div className="space-y-3 rounded-lg border bg-muted/30 p-4">
              <div className="flex items-center justify-between">
                <p className="flex items-center gap-1.5 text-sm font-medium">
                  <Factory className="size-4" />
                  {selected.full_name}
                </p>
                <Button variant="ghost" size="icon" onClick={clearSelection} title="إلغاء التحديد">
                  <X className="size-4" />
                </Button>
              </div>
              <div className="space-y-1.5">
                <Label htmlFor={`fmp-address-${selected.id}`}>العنوان (نصي)</Label>
                <Input
                  id={`fmp-address-${selected.id}`}
                  value={address}
                  onChange={(e) => setAddress(e.target.value)}
                  placeholder="مثال: المنطقة الصناعية، مدينة نصر، مبنى 12"
                />
              </div>
              <div className="space-y-1.5">
                <Label htmlFor={`fmp-maps-url-${selected.id}`}>رابط خرائط جوجل (اختياري)</Label>
                <Input
                  id={`fmp-maps-url-${selected.id}`}
                  dir="ltr"
                  value={mapsUrlValue}
                  onChange={(e) => setMapsUrlValue(e.target.value)}
                  placeholder="https://www.google.com/maps/place/..."
                />
                <p className="text-xs text-muted-foreground">
                  إن وُجد، يُستخدم هذا الرابط مباشرة بدلًا من العنوان النصي أو تحديد الخريطة — أدق وأسرع للمندوب.
                </p>
              </div>
              <p className="text-xs text-muted-foreground">
                {pin
                  ? `الموقع المحدد على الخريطة: ${pin.lat.toFixed(5)}, ${pin.lng.toFixed(5)} — انقر على الخريطة أعلاه لتغييره أو اسحب العلامة الزرقاء`
                  : "لا يوجد موقع محدد على الخريطة بعد — انقر في أي مكان على الخريطة أعلاه لتحديده"}
              </p>
              {error && <p className="text-sm text-destructive">{error}</p>}
              <Button size="sm" onClick={save} disabled={pending}>
                {pending && <Loader2 className="animate-spin" />}
                حفظ
              </Button>
            </div>
          )}
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">المصانع ({factories.length})</CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          {factories.length === 0 ? (
            <EmptyState icon={Factory} title="لا يوجد حساب مصنع بعد" />
          ) : (
            <Table>
              <TableHeader>
                <TableRow>
                  <TableHead>الاسم</TableHead>
                  <TableHead>الهاتف</TableHead>
                  <TableHead>الموقع</TableHead>
                  <TableHead>الحالة</TableHead>
                  <TableHead />
                </TableRow>
              </TableHeader>
              <TableBody>
                {factories.map((member) => {
                  const url = mapsUrlFor({
                    maps_url: member.maps_url,
                    address: member.address,
                    lat: member.lat,
                    lng: member.lng,
                  });
                  return (
                    <TableRow key={member.id} className={member.id === selectedId ? "bg-muted/50" : undefined}>
                      <TableCell className="font-medium">
                        <button type="button" className="text-start hover:underline" onClick={() => select(member)}>
                          {member.full_name}
                        </button>
                      </TableCell>
                      <TableCell className="text-muted-foreground" dir="ltr">
                        {member.phone ?? "—"}
                      </TableCell>
                      <TableCell>
                        <button
                          type="button"
                          className="flex items-center gap-1 text-start text-sm hover:underline"
                          onClick={() => select(member)}
                        >
                          <MapPin className="size-3.5 text-muted-foreground" />
                          {member.address || (url ? "موقع محدد بدون عنوان" : "تحديد الموقع")}
                        </button>
                      </TableCell>
                      <TableCell>
                        {member.is_active ? (
                          <Badge variant="success">نشط</Badge>
                        ) : (
                          <Badge variant="destructive">موقوف</Badge>
                        )}
                      </TableCell>
                      <TableCell>
                        <div className="flex gap-2">
                          <ToggleActiveButton
                            userId={member.id}
                            isActive={member.is_active}
                            onToggled={(isActive) => onToggled(member.id, isActive)}
                          />
                          <ResetPasswordButton userId={member.id} />
                        </div>
                      </TableCell>
                    </TableRow>
                  );
                })}
              </TableBody>
            </Table>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
