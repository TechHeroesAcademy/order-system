"use client";

import { useRef, useState, useTransition } from "react";
import { toast } from "sonner";
import { Loader2, Factory, Wand2 } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Card, CardContent, CardHeader, CardTitle, CardDescription } from "@/components/ui/card";
import { createStaffAccountAction, resolveMapsUrlCoordsAction } from "@/lib/actions/admin";
import { createStaffAccountSchema } from "@/lib/domain/validators";
import type { Profile } from "@/types/database";

/**
 * "إضافة مصنع" — its own tab next to "الموظفون"/"المصانع" (not a dialog,
 * not a separate page/browser tab), so creating a factory account gets a
 * form with room to breathe instead of squeezing into the same dialog as
 * driver/moderator/owner accounts. Pasting a Google Maps link here
 * auto-extracts its coordinates (resolveMapsUrlCoordsAction) and sets the
 * pin right away — no separate "now go click the map" step needed unless
 * the link didn't carry coordinates (a plain text-search link, or one that
 * couldn't be resolved), in which case the old fallback still applies:
 * pick this factory from the table in the Factories tab and click its spot
 * on the map.
 */
export function AddFactoryPanel({ onCreated }: { onCreated: (profile: Profile) => void }) {
  const [fullName, setFullName] = useState("");
  const [phone, setPhone] = useState("");
  const [email, setEmail] = useState("");
  const [address, setAddress] = useState("");
  const [mapsUrl, setMapsUrl] = useState("");
  const [pin, setPin] = useState<{ lat: number; lng: number } | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [pending, startTransition] = useTransition();

  const [extractStatus, setExtractStatus] = useState<"idle" | "loading" | "found" | "not_found">("idle");
  const [extracting, startExtractTransition] = useTransition();
  const lastExtractedUrlRef = useRef<string | null>(null);

  function reset() {
    setFullName("");
    setPhone("");
    setEmail("");
    setAddress("");
    setMapsUrl("");
    setPin(null);
    setError(null);
    setExtractStatus("idle");
    lastExtractedUrlRef.current = null;
  }

  /** Same behavior as the edit card in FactoriesMapPanel — see the comment there. */
  function handleMapsUrlBlur() {
    const trimmed = mapsUrl.trim();
    if (!trimmed || trimmed === lastExtractedUrlRef.current) return;
    lastExtractedUrlRef.current = trimmed;
    setExtractStatus("loading");
    startExtractTransition(async () => {
      const res = await resolveMapsUrlCoordsAction(trimmed);
      if (res.ok && res.data) {
        setPin(res.data);
        setExtractStatus("found");
      } else {
        setExtractStatus("not_found");
      }
    });
  }

  function submit() {
    const parsed = createStaffAccountSchema.safeParse({
      full_name: fullName,
      phone,
      email: email || undefined,
      role: "factory",
      region_names: [],
      address,
      maps_url: mapsUrl,
      lat: pin?.lat ?? null,
      lng: pin?.lng ?? null,
    });
    if (!parsed.success) {
      setError(parsed.error.issues[0]?.message ?? "بيانات غير صالحة");
      return;
    }
    setError(null);
    startTransition(async () => {
      const res = await createStaffAccountAction(parsed.data);
      if (!res.ok) {
        setError(res.error);
        return;
      }
      const profile: Profile = {
        id: res.data.userId,
        full_name: parsed.data.full_name,
        phone: parsed.data.phone,
        role: "factory",
        region_id: null,
        address: parsed.data.address?.trim() || null,
        lat: parsed.data.lat ?? null,
        lng: parsed.data.lng ?? null,
        maps_url: parsed.data.maps_url?.trim() || null,
        is_active: true,
        password_set: false,
        created_at: new Date().toISOString(),
        updated_at: new Date().toISOString(),
      };
      // The parent (TeamManager) switches to the Factories tab right after
      // this fires, where the new row now appears in the table — that jump
      // is the success confirmation, so there's no separate "done" screen
      // to show here (it would just flash and disappear).
      onCreated(profile);
      toast.success(
        pin
          ? `تم إنشاء حساب المصنع "${parsed.data.full_name}" وتحديد موقعه على الخريطة من الرابط`
          : `تم إنشاء حساب المصنع "${parsed.data.full_name}" — لتحديد موقعه بدقة، اختره من الجدول ثم انقر على مكانه على الخريطة`,
      );
      reset();
    });
  }

  return (
    <Card className="mx-auto max-w-lg">
      <CardHeader>
        <CardTitle className="flex items-center gap-2 text-base">
          <Factory className="size-4" />
          إضافة مصنع جديد
        </CardTitle>
        <CardDescription>يسجل دخوله برقم هاتفه، وينشئ كلمة مرور بنفسه أول مرة يدخل بها.</CardDescription>
      </CardHeader>
      <CardContent className="space-y-3">
        <div className="space-y-1.5">
          <Label htmlFor="factory-name">اسم المصنع</Label>
          <Input id="factory-name" value={fullName} onChange={(e) => setFullName(e.target.value)} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="factory-phone">رقم الهاتف</Label>
          <Input
            id="factory-phone"
            dir="ltr"
            placeholder="01xxxxxxxxx"
            value={phone}
            onChange={(e) => setPhone(e.target.value)}
          />
          <p className="text-xs text-muted-foreground">هذا هو رقم تسجيل الدخول — لازم يكون صحيحًا.</p>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="factory-email">البريد الإلكتروني (اختياري)</Label>
          <Input id="factory-email" type="email" dir="ltr" value={email} onChange={(e) => setEmail(e.target.value)} />
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="factory-address">عنوان المصنع (اختياري)</Label>
          <Input
            id="factory-address"
            value={address}
            onChange={(e) => setAddress(e.target.value)}
            placeholder="مثال: المنطقة الصناعية، مدينة نصر، مبنى 12"
          />
          <p className="text-xs text-muted-foreground">يظهر هذا العنوان للمندوب عند تسليم أو استلام أوردر من هذا المصنع.</p>
        </div>
        <div className="space-y-1.5">
          <Label htmlFor="factory-maps-url">رابط خرائط جوجل (اختياري)</Label>
          <Input
            id="factory-maps-url"
            dir="ltr"
            value={mapsUrl}
            onChange={(e) => setMapsUrl(e.target.value)}
            onBlur={handleMapsUrlBlur}
            disabled={extracting}
            placeholder="https://www.google.com/maps/place/..."
          />
          <p className="text-xs text-muted-foreground">
            إن وُجد، يُستخدم مباشرة بدلًا من العنوان النصي أو تحديد الخريطة — أدق وأسرع للمندوب. سيتم تحديد موقعه
            على الخريطة تلقائيًا من هذا الرابط.
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
              تم تحديد الموقع تلقائيًا من الرابط — سيظهر مباشرة على خريطة المصانع.
            </p>
          )}
          {extractStatus === "not_found" && (
            <p className="text-xs text-muted-foreground">
              لم نستطع استخراج إحداثيات من هذا الرابط — يمكن تحديد الموقع يدويًا لاحقًا من خريطة المصانع.
            </p>
          )}
        </div>
        <p className="text-xs text-muted-foreground">
          إن لم يحتوِ الرابط على موقع دقيق، يمكن تحديد موقع المصنع لاحقًا على الخريطة — من تبويب &quot;المصانع&quot;،
          اختره من الجدول ثم انقر على مكانه على الخريطة العامة.
        </p>
        {error && <p className="text-sm text-destructive">{error}</p>}
        <Button className="w-full" onClick={submit} disabled={pending || extracting}>
          {pending && <Loader2 className="animate-spin" />}
          إنشاء حساب المصنع
        </Button>
      </CardContent>
    </Card>
  );
}
