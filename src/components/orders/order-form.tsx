"use client";

import { useId, useState } from "react";
import { useForm, useWatch } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { toast } from "sonner";
import { History, Loader2, PackageCheck } from "lucide-react";
import { orderFormSchema, type OrderFormValues } from "@/lib/domain/validators";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { RegionDatalist } from "@/components/shared/region-datalist";
import { Textarea } from "@/components/ui/textarea";
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from "@/components/ui/form";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Card, CardContent } from "@/components/ui/card";
import { RepeatCustomerDialog } from "@/components/orders/repeat-customer-dialog";
import { lookupCustomerHistoryAction } from "@/lib/actions/orders";
import {
  buildRepeatCustomerNotice,
  isPhoneLookupReady,
  phoneMatchKey,
  type RepeatCustomerNotice,
} from "@/lib/domain/customer-history";
import type { CustomerOrderHistory, Region, Factory, NewOrderResult } from "@/types/database";
import type { ActionResult } from "@/lib/actions/types";

export function OrderForm({
  regions,
  factories = [],
  requireFactory = false,
  showFactoryField = true,
  action,
  submitLabel = "إنشاء الأوردر",
  showRegionHint = true,
}: {
  regions: Region[];
  factories?: Factory[];
  requireFactory?: boolean;
  showFactoryField?: boolean;
  action: (values: OrderFormValues) => Promise<ActionResult<NewOrderResult>>;
  showRegionHint?: boolean;
  submitLabel?: string;
}) {
  const [result, setResult] = useState<NewOrderResult | null>(null);
  const [submitting, setSubmitting] = useState(false);
  const regionListId = useId();

  const [cached, setCached] = useState<{ key: string; history: CustomerOrderHistory } | null>(null);
  const [checking, setChecking] = useState(false);
  const [notice, setNotice] = useState<RepeatCustomerNotice | null>(null);
  const [pending, setPending] = useState<OrderFormValues | null>(null);

  async function historyFor(phone: string): Promise<CustomerOrderHistory | null> {
    const key = phoneMatchKey(phone);
    if (!isPhoneLookupReady(phone)) return null;
    if (cached?.key === key) return cached.history;

    setChecking(true);
    const res = await lookupCustomerHistoryAction(phone);
    setChecking(false);
    if (!res.ok) return null;

    setCached({ key, history: res.data });
    return res.data;
  }

  function onPhoneBlur(phone: string) {
    void historyFor(phone);
  }

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

  const watchedPhone = useWatch({ control: form.control, name: "customer_phone" });
  const watchedName = useWatch({ control: form.control, name: "customer_name" });
  const inlineNotice = (() => {
    if (!cached || cached.key !== phoneMatchKey(watchedPhone ?? "")) return null;
    const built = buildRepeatCustomerNotice(cached.history, watchedName ?? "");
    return built.isRepeat ? built : null;
  })();

  async function submitOrder(values: OrderFormValues) {
    setSubmitting(true);
    const res = await action(values);
    setSubmitting(false);

    if (!res.ok) {
      toast.error(res.error);
      return;
    }

    setResult(res.data);
    form.reset();
    setCached(null);
  }

  async function onSubmit(values: OrderFormValues) {
    if (showFactoryField && requireFactory && !values.factory_id) {
      form.setError("factory_id", { message: "اختر المصنع" });
      toast.error("يجب اختيار المصنع لهذا الأوردر");
      return;
    }

    const history = await historyFor(values.customer_phone);
    if (history) {
      const built = buildRepeatCustomerNotice(history, values.customer_name);
      if (built.isRepeat) {
        setNotice(built);
        setPending(values);
        return;
      }
    }

    await submitOrder(values);
  }

  function onRepeatConfirm() {
    const values = pending;
    setNotice(null);
    setPending(null);
    if (values) void submitOrder(values);
  }

  function onRepeatCancel() {
    setNotice(null);
    setPending(null);
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
                  <Input
                    dir="ltr"
                    placeholder="01xxxxxxxxx"
                    {...field}
                    onBlur={(e) => {
                      field.onBlur();
                      onPhoneBlur(e.target.value);
                    }}
                  />
                </FormControl>
                {checking && (
                  <p className="flex items-center gap-1.5 text-xs text-muted-foreground">
                    <Loader2 className="size-3 animate-spin" />
                    جارٍ التحقق من أوردرات العميل السابقة…
                  </p>
                )}
                {!checking && inlineNotice && (
                  <p className="flex items-center gap-1.5 text-xs font-medium text-warning-foreground">
                    <History className="size-3 shrink-0" />
                    عميل مكرر — هذا سيكون الأوردر رقم {inlineNotice.orderIndex} له
                  </p>
                )}
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
              <FormLabel>رابط موقع العميل على خرائط جوجل</FormLabel>
              <FormControl>
                <Input
                  dir="ltr"
                  placeholder="https://www.google.com/maps/place/..."
                  {...field}
                  value={field.value ?? ""}
                />
              </FormControl>
              <p className="text-xs text-muted-foreground">
                اطلب من العميل رابط موقعه من تطبيق خرائط جوجل (مشاركة ↦ نسخ الرابط) والصقه هنا. الرابط يفتح
                موقعه بالضبط للمندوب، بينما البحث بالعنوان النصي قد يوصله لشارع آخر.
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
                {showRegionHint && (
                  <p className="text-xs text-muted-foreground">
                    اكتب اسم المنطقة بنفسك — تُستخدم لترشيح مندوب تلقائيًا من نفس المنطقة.
                  </p>
                )}
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

        {showFactoryField && (factories.length > 0 || requireFactory) && (
          <FormField
            control={form.control}
            name="factory_id"
            render={({ field }) => (
              <FormItem>
                <FormLabel>{requireFactory ? "المصنع" : "المصنع (اختياري)"}</FormLabel>
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
                      {!requireFactory && (
                        <SelectItem value="unassigned">بدون تحديد — يظهر لكل المصانع</SelectItem>
                      )}
                      {factories.map((f) => (
                        <SelectItem key={f.id} value={f.id}>
                          {f.name}
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

        <Button type="submit" className="w-full" disabled={submitting || checking}>
          {(submitting || checking) && <Loader2 className="animate-spin" />}
          {submitLabel}
        </Button>
      </form>

      <RepeatCustomerDialog
        notice={notice}
        open={Boolean(notice)}
        onCancel={onRepeatCancel}
        onConfirm={onRepeatConfirm}
      />
    </Form>
  );
}
