"use client";

import { useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { toast } from "sonner";
import { Loader2, PackageCheck } from "lucide-react";
import { orderFormSchema, type OrderFormValues } from "@/lib/domain/validators";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from "@/components/ui/form";
import { Select, SelectContent, SelectItem, SelectTrigger, SelectValue } from "@/components/ui/select";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Card, CardContent } from "@/components/ui/card";
import type { Region, NewOrderResult } from "@/types/database";
import type { ActionResult } from "@/lib/actions/types";

export function OrderForm({
  regions,
  action,
  submitLabel = "إنشاء الأوردر",
}: {
  regions: Region[];
  action: (values: OrderFormValues) => Promise<ActionResult<NewOrderResult>>;
  submitLabel?: string;
}) {
  const [result, setResult] = useState<NewOrderResult | null>(null);
  const [submitting, setSubmitting] = useState(false);

  const form = useForm<OrderFormValues>({
    resolver: zodResolver(orderFormSchema),
    defaultValues: {
      customer_name: "",
      customer_phone: "",
      customer_address: "",
      region_id: null,
      pieces_count: 1,
      piece_details: "",
      color: "",
      work_required: "",
      customer_notes: "",
    },
  });

  async function onSubmit(values: OrderFormValues) {
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
          <div className="rounded-lg border bg-muted/40 p-4 text-center">
            <p className="text-sm text-muted-foreground">كود تأكيد التسليم — يُكتب على إيصال العميل الورقي</p>
            <p className="mt-1 text-3xl font-bold tracking-widest tabular-nums">{result.delivery_code}</p>
            <p className="mt-1 text-xs text-muted-foreground">لن يظهر هذا الكود مرة أخرى بعد الآن</p>
          </div>
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

        <div className="grid gap-4 sm:grid-cols-2">
          <FormField
            control={form.control}
            name="region_id"
            render={({ field }) => (
              <FormItem>
                <FormLabel>المنطقة</FormLabel>
                <Select value={field.value ?? undefined} onValueChange={field.onChange}>
                  <FormControl>
                    <SelectTrigger className="w-full">
                      <SelectValue placeholder="اختر المنطقة" />
                    </SelectTrigger>
                  </FormControl>
                  <SelectContent>
                    {regions.map((r) => (
                      <SelectItem key={r.id} value={r.id}>
                        {r.name}
                      </SelectItem>
                    ))}
                  </SelectContent>
                </Select>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={form.control}
            name="pieces_count"
            render={({ field }) => (
              <FormItem>
                <FormLabel>عدد القطع</FormLabel>
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

        <div className="grid gap-4 sm:grid-cols-2">
          <FormField
            control={form.control}
            name="piece_details"
            render={({ field }) => (
              <FormItem>
                <FormLabel>تفاصيل القطع</FormLabel>
                <FormControl>
                  <Input {...field} value={field.value ?? ""} />
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
                <FormLabel>اللون</FormLabel>
                <FormControl>
                  <Input {...field} value={field.value ?? ""} />
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
              <FormLabel>المطلوب عمله</FormLabel>
              <FormControl>
                <Input {...field} value={field.value ?? ""} />
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
