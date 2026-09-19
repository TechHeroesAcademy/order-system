"use client";

import { useMemo, useRef, useState, useTransition } from "react";
import dynamic from "next/dynamic";
import { toast } from "sonner";
import { Loader2, Factory as FactoryIcon, MapPin, MapPinOff, Map as MapIcon, X, Wand2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Badge } from "@/components/ui/badge";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { EmptyState } from "@/components/shared/empty-state";
import { resolveMapsUrlCoordsAction } from "@/lib/actions/admin";
import { updateFactoryAction } from "@/lib/actions/factories";
import { factoryDetailsSchema } from "@/lib/domain/validators";
import { mapsUrlFor } from "@/lib/domain/maps";
import { ToggleFactoryActiveButton, DeleteFactoryButton } from "./factory-actions";
import type { Factory } from "@/types/database";
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
  onDeleted,
  canDelete,
}: {
  factories: Factory[];
  onSaved: (
    id: string,
    next: { address: string | null; lat: number | null; lng: number | null; maps_url: string | null },
  ) => void;
  onToggled: (id: string, isActive: boolean) => void;
  onDeleted: (id: string) => void;
  /** Owner only — deleteFactoryAction rejects a Moderator server-side too, this just hides the control. */
  canDelete: boolean;
}) {
  const [selectedId, setSelectedId] = useState<string | null>(null);
  const [address, setAddress] = useState("");
  const [mapsUrlValue, setMapsUrlValue] = useState("");
  const [pin, setPin] = useState<{ lat: number; lng: number } | null>(null);
  // Set only right after a successful link extraction — see FactoriesMap's
  // focusPin prop. Kept separate from `pin` so selecting a factory or
  // clicking/dragging on the map (which don't need the view to jump) don't
  // also trigger a pan.
  const [focusPin, setFocusPin] = useState<{ lat: number; lng: number } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  // "extract the lat/lng from the link and pin on the map" — tried once per
  // distinct pasted value (the ref guards against re-firing on a blur that
  // didn't actually change anything, e.g. tabbing through with no edit).
  const [extractStatus, setExtractStatus] = useState<"idle" | "loading" | "found" | "not_found">("idle");
  const [extracting, startExtractTransition] = useTransition();
  const lastExtractedUrlRef = useRef<string | null>(null);

  const selected = factories.find((f) => f.id === selectedId) ?? null;

  const pins: FactoryPin[] = useMemo(
    () =>
      factories
        .filter((f): f is Factory & { lat: number; lng: number } => f.lat != null && f.lng != null)
        .map((f) => ({ id: f.id, name: f.name, address: f.address, lat: f.lat, lng: f.lng })),
    [factories],
  );

  function select(factory: Factory) {
    setSelectedId(factory.id);
    setAddress(factory.address ?? "");
    setMapsUrlValue(factory.maps_url ?? "");
    setPin(factory.lat != null && factory.lng != null ? { lat: factory.lat, lng: factory.lng } : null);
    setFocusPin(null);
    setError(null);
    setExtractStatus("idle");
    lastExtractedUrlRef.current = factory.maps_url ?? null;
  }

  /**
   * Fires when the موقع field loses focus (covers both pasting a link and
   * typing one out) — extracts coordinates from it and drops the pin on
   * the map automatically, same as clicking the map by hand would. Only
   * ever *sets* a pin from a successful extraction; it never clears an
   * existing one just because the link didn't carry coordinates, so
   * pasting a plain-text search link after already placing a pin by hand
   * doesn't wipe that out.
   */
  function handleMapsUrlBlur() {
    const trimmed = mapsUrlValue.trim();
    if (!trimmed || trimmed === lastExtractedUrlRef.current) return;
    lastExtractedUrlRef.current = trimmed;
    setExtractStatus("loading");
    startExtractTransition(async () => {
      const res = await resolveMapsUrlCoordsAction(trimmed);
      if (res.ok && res.data) {
        setPin(res.data);
        setFocusPin(res.data);
        setExtractStatus("found");
      } else {
        setExtractStatus("not_found");
      }
    });
  }

  function clearSelection() {
    setSelectedId(null);
    setError(null);
    setExtractStatus("idle");
    setFocusPin(null);
  }

  function save() {
    if (!selected) return;
    const parsed = factoryDetailsSchema.safeParse({
      name: selected.name,
      phone: selected.phone,
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
      const res = await updateFactoryAction(selected.id, parsed.data);
      if (!res.ok) {
        setError(res.error);
        return;
      }
      onSaved(selected.id, {
        address: parsed.data.address?.trim() || null,
        lat: parsed.data.lat ?? null,
        lng: parsed.data.lng ?? null,
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
          {pins.length === 0 && factories.length > 0 ? (
            // The map only ever plots a factory once someone explicitly sets
            // its pin here — creating a factory account (or just giving it a
            // text address) doesn't place it on the map by itself, so a
            // freshly-added team with no pins set yet is expected to render
            // as an empty map. Called out explicitly instead of leaving that
            // as a silent blank map, which reads as broken.
            <Alert variant="warning">
              <MapPinOff className="size-4" />
              <AlertTitle>لا يوجد أي مصنع له موقع محدد على الخريطة بعد</AlertTitle>
              <AlertDescription>
                إضافة عنوان نصي عند إنشاء المصنع لا يضعه تلقائيًا على الخريطة — لتحديد موقعه بدقة: اختر المصنع من
                الجدول أسفل الخريطة، ثم انقر على مكانه عليها.
              </AlertDescription>
            </Alert>
          ) : (
            <p className="text-xs text-muted-foreground">
              انقر على أي علامة لتعديل بيانات المصنع، أو اختره من الجدول أدناه. إن لم يكن للمصنع المختار موقع محدد
              بعد، انقر في أي مكان على الخريطة لتحديده.
            </p>
          )}
          <FactoriesMap
            factories={pins}
            selectedId={selectedId}
            selectedPin={pin}
            focusPin={focusPin}
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
                  <FactoryIcon className="size-4" />
                  {selected.name}
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
                  onBlur={handleMapsUrlBlur}
                  disabled={extracting}
                  placeholder="https://www.google.com/maps/place/..."
                />
                <p className="text-xs text-muted-foreground">
                  إن وُجد، يُستخدم هذا الرابط مباشرة بدلًا من العنوان النصي أو تحديد الخريطة — أدق وأسرع للمندوب.
                </p>
                {extractStatus === "loading" && (
                  <p className="flex items-center gap-1.5 text-xs text-muted-foreground">
                    <Loader2 className="size-3 animate-spin" />
                    جارٍ استخراج الموقع من الرابط...
                  </p>
                )}
                {extractStatus === "found" && (
                  <p className="flex items-center gap-1.5 text-xs text-emerald-600">
                    <Wand2 className="size-3" />
                    تم تحديد الموقع تلقائيًا من الرابط — عدّله بالسحب على الخريطة لو احتاج ضبطًا.
                  </p>
                )}
                {extractStatus === "not_found" && (
                  <p className="text-xs text-muted-foreground">
                    لم نستطع استخراج إحداثيات من هذا الرابط — حدد الموقع يدويًا بالنقر على الخريطة أعلاه.
                  </p>
                )}
              </div>
              <p className="text-xs text-muted-foreground">
                {pin
                  ? `الموقع المحدد على الخريطة: ${pin.lat.toFixed(5)}, ${pin.lng.toFixed(5)} — انقر على الخريطة أعلاه لتغييره أو اسحب العلامة الزرقاء`
                  : "لا يوجد موقع محدد على الخريطة بعد — انقر في أي مكان على الخريطة أعلاه لتحديده"}
              </p>
              {error && <p className="text-sm text-destructive">{error}</p>}
              <Button size="sm" onClick={save} disabled={pending || extracting}>
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
            <EmptyState icon={FactoryIcon} title="لا يوجد حساب مصنع بعد" />
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
                          {member.name}
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
                          <ToggleFactoryActiveButton
                            factoryId={member.id}
                            isActive={member.is_active}
                            onToggled={(isActive) => onToggled(member.id, isActive)}
                          />
                          {canDelete && (
                            <DeleteFactoryButton
                              factoryId={member.id}
                              name={member.name}
                              onDeleted={() => onDeleted(member.id)}
                            />
                          )}
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
