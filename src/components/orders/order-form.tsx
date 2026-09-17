"use client";

import { useId, useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { toast } from "sonner";
import { Loader2, PackageCheck } from "lucide-react";
import { orderFormSchema, type OrderFormValues } from "@/lib/domain/validators";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { RegionDatalist } from "@/components/shared/region-datalist";
import { Textarea } from "@/components/ui/textarea";
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from "@/components/ui/form";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Card, CardContent } from "@/components/ui/card";
import type { Region, Profile, NewOrderResult } from "@/types/database";
import type { ActionResult } from "@/lib/actions/types";

export function OrderForm({
  regions,
  factories = [],
  drivers = [],
  requireDriverAndFactory = false,
  showDistributionFields = true,
  action,
  submitLabel = "إنشاء الأوردر",
}: {
  regions: Region[];
  /** Active factory accounts, for the "route to factory" field below — leave the field unassigned and it stays visible to every factory account (unless requireDriverAndFactory). */
  factories?: Profile[];
  /** Active driver accounts, for the "assign a driver" field below. */
  drivers?: Profile[];
  /** Owner creating an order must pick both a driver and a factory up front. See createModeratorOrderAction. Ignored when showDistributionFields is false. */
  requireDriverAndFactory?: boolean;
  /**
   * false hides the factory/driver fields entirely — used for a Moderator,
   * who can no longer assign either (migration 0024): the region alone is
   * enough for the system to auto-suggest a driver, pending the Owner's
   * approval, and the factory is left for the Owner to set afterward.
   */
  showDistributionFields?: boolean;
  action: (values: OrderFormValues) => Promise<ActionResult<NewOrderResult>>;
  submitLabel?: string;
}) {
  const [result, setResult] = useState<NewOrderResult | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const regionListId = useId();

  const form = useForm<OrderFormValues>({
    resolver: zodResolver(orderFormSchema),
    defaultValues: {
      customer_name: "",
      customer_phone: "",
      customer_address: "",
      customer_maps_url: "",
      region_name: "",
      pieces_count: 1,
      piece_details: "",
      color: "",
      work_required: "",
      customer_notes: "",
      factory_id: null,
      driver_id: null,
    },
  });

  async function onSubmit(values: OrderFormValues) {
    if (showDistributionFields && requireDriverAndFactory) {
      let missing = false;
      if (!values.driver_id) {
        form.setError("driver_id", { message: "اختر المندوب" });
        missing = true;
      }
      if (!values.factory_id) {
        form.setError("factory_id", { message: "اختر المصنع" });
        missing = true;
      }
      if (missing) {
        toast.error("يجب اختيار المندوب والمصنع لهذا الأوردر");
        return;
      }
    }

    setSubmitting(true);
    const res = await action(values);
    setSubmitting(false);

    if (!res.ok) {
      toast.error(res.error);
      return;
    }

    setResult(res.data);
    form.reset();
  }

  if (result) {
    return (
      <Card>
        <CardContent className="space-y-4 pt-6">
          <Alert variant="success">
            <PackageCheck className="size-5" />
            <AlertTitle>تم إنشاء الأوردر بنجاح</AlertTitle>
            <AlertDescription>
              رقم الأوردر: <span className="font-bold">{result.order_number}</span>
            </AlertDescription>
          </Alert>
          <div className="grid gap-3 sm:grid-cols-2">
            <div className="rounded-lg border bg-muted/40 p-4 text-center">
              <p className="text-sm text-muted-foreground">كود الاستلام من العميل — يطلبه المندوب قبل الاستلام</p>
              <p className="mt-1 text-3xl font-bold tracking-widest tabular-nums">{result.pickup_code}</p>
            </div>
            <div className="rounded-lg border bg-muted/40 p-4 text-center">
              <p className="text-sm text-muted-foreground">كود تأكيد التسليم — يُكتب على إيصال العميل الورقي</p>
              <p className="mt-1 text-3xl font-bold tracking-widest tabular-nums">{result.delivery_code}</p>
            </div>
          </div>
          <p className="text-center text-xs text-muted-foreground">لن يظهر هذان الكودان مرة أخرى بعد الآن هنا — يمكن لاحقًا إظهارهما من صفحة الأوردر</p>
          <Button className="w-full" variant="outline" onClick={() => setResult(null)}>
            إنشاء أوردر آخر
          </Button>
        </CardContent>
      </Card>
    );
  }

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4">
        <div className="grid gap-4 sm:grid-cols-2">
          <FormField
            control={form.control}
            name="customer_name"
            render={({ field }) => (
              <FormItem>
                <FormLabel>اسم العميل</FormLabel>
                <FormControl>
                  <Input {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="customer_phone"
            render={({ field }) => (
              <FormItem>
                <FormLabel>رقم الهاتف</FormLabel>
                <FormControl>
                  <Input dir="ltr" placeholder="01xxxxxxxxx" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
        </div>

        <FormField
          control={form.control}
          name="customer_address"
          render={({ field }) => (
            <FormItem>
              <FormLabel>العنوان</FormLabel>
              <FormControl>
                <Textarea rows={2} {...field} />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="customer_maps_url"
          render={({ field }) => (
            <FormItem>
              <FormLabel>رابط الموقع على خرائط جوجل (اختياري)</FormLabel>
              <FormControl>
                <Input
                  dir="ltr"
                  placeholder="https://www.google.com/maps/place/..."
                  {...field}
                  value={field.value ?? ""}
                />
              </FormControl>
              <p className="text-xs text-muted-foreground">
                إن كان لدى العميل رابط موقعه من تطبيق خرائط جوجل (مشاركة ↦ نسخ الرابط)، الصقه هنا ليفتح المندوب
                موقعه الدقيق مباشرة بدلًا من البحث عن العنوان النصي.
              </p>
              <FormMessage />
            </FormItem>
          )}
        />

        <div className="grid gap-4 sm:grid-cols-2">
          <FormField
            control={form.control}
            name="region_name"
            render={({ field }) => (
              <FormItem>
                <FormLabel>المنطقة</FormLabel>
                <FormControl>
                  <Input
                    {...field}
                    list={regionListId}
                    placeholder="اكتب اسم المنطقة (مثال: المعادي، مدينة نصر)"
                  />
                </FormControl>
                <RegionDatalist id={regionListId} regions={regions} />
                <p className="text-xs text-muted-foreground">
                  اكتب اسم المنطقة بنفسك — تُستخدم لترشيح مندوب تلقائيًا من نفس المنطقة.
                </p>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="pieces_count"
            render={({ field }) => (
              <FormItem>
                <FormLabel>عدد الأواني</FormLabel>
                <FormControl>
                  <Input
                    type="number"
                    min={1}
                    value={field.value}
                    onChange={(e) => field.onChange(e.target.valueAsNumber || 0)}
                    onBlur={field.onBlur}
                    name={field.name}
                    ref={field.ref}
                  />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
        </div>

        {showDistributionFields && (factories.length > 0 || requireDriverAndFactory) && (
          <FormField
            control={form.control}
            name="factory_id"
            render={({ field }) => (
              <FormItem>
                <FormLabel>{requireDriverAndFactory ? "المصنع" : "المصنع (اختياري)"}</FormLabel>
                {factories.length > 0 ? (
                  <Select
                    value={field.value ?? "unassigned"}
                    onValueChange={(v) => field.onChange(v === "unassigned" ? null : v)}
                  >
                    <FormControl>
                      <SelectTrigger className="w-full">
                        <SelectValue placeholder="بدون تحديد — يظهر لكل المصانع" />
                      </SelectTrigger>
                    </FormControl>
                    <SelectContent>
                      {!requireDriverAndFactory && (
                        <SelectItem value="unassigned">بدون تحديد — يظهر لكل المصانع</SelectItem>
                      )}
                      {factories.map((f) => (
                        <SelectItem key={f.id} value={f.id}>
                          {f.full_name}
                          {f.address ? ` — ${f.address}` : ""}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                ) : (
                  <p className="text-sm text-destructive">
                    لا يوجد حساب مصنع مفعّل — أضف واحدًا من إدارة الفريق أولًا
                  </p>
                )}
                <FormMessage />
              </FormItem>
            )}
          />
        )}

        {showDistributionFields && (drivers.length > 0 || requireDriverAndFactory) && (
          <FormField
            control={form.control}
            name="driver_id"
            render={({ field }) => (
              <FormItem>
                <FormLabel>{requireDriverAndFactory ? "المندوب" : "المندوب (اختياري)"}</FormLabel>
                {drivers.length > 0 ? (
                  <Select
                    value={field.value ?? "unassigned"}
                    onValueChange={(v) => field.onChange(v === "unassigned" ? null : v)}
                  >
                    <FormControl>
                      <SelectTrigger className="w-full">
                        <SelectValue placeholder="بدون تحديد — يُسند لاحقًا من التوزيع" />
                      </SelectTrigger>
                    </FormControl>
                    <SelectContent>
                      {!requireDriverAndFactory && (
                        <SelectItem value="unassigned">بدون تحديد — يُسند لاحقًا من التوزيع</SelectItem>
                      )}
                      {drivers.map((d) => (
                        <SelectItem key={d.id} value={d.id}>
                          {d.full_name}
                        </SelectItem>
                      ))}
                    </SelectContent>
                  </Select>
                ) : (
                  <p className="text-sm text-destructive">
                    لا يوجد مندوب مفعّل — أضف واحدًا من إدارة الفريق أولًا
                  </p>
                )}
                <FormMessage />
              </FormItem>
            )}
          />
        )}

        <div className="grid gap-4 sm:grid-cols-2">
          <FormField
            control={form.control}
            name="piece_details"
            render={({ field }) => (
              <FormItem>
                <FormLabel>تفاصيل الإناء</FormLabel>
                <FormControl>
                  <Input {...field} value={field.value ?? ""} placeholder="مثال: حلة كبيرة، طاسة تيفال..." />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="color"
            render={({ field }) => (
              <FormItem>
                <FormLabel>اللون الجديد</FormLabel>
                <FormControl>
                  <Input {...field} value={field.value ?? ""} placeholder="مثال: أسود، رمادي فضي..." />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
        </div>

        <FormField
          control={form.control}
          name="work_required"
          render={({ field }) => (
            <FormItem>
              <FormLabel>نوع الخدمة المطلوبة</FormLabel>
              <FormControl>
                <Input {...field} value={field.value ?? ""} placeholder="مثال: إعادة طلاء، تلميع، إصلاح مقبض..." />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />

        <FormField
          control={form.control}
          name="customer_notes"
          render={({ field }) => (
            <FormItem>
              <FormLabel>ملاحظات العميل (اختياري)</FormLabel>
              <FormControl>
                <Textarea rows={2} {...field} value={field.value ?? ""} />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />

        <Button type="submit" className="w-full" disabled={submitting}>
          {submitting && <Loader2 className="animate-spin" />}
          {submitLabel}
        </Button>
      </form>
    </Form>
  );
}
