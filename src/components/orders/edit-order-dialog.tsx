"use client";

import { useId, useState } from "react";
import { useRouter } from "next/navigation";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { toast } from "sonner";
import { Loader2, Pencil } from "lucide-react";
import { editOrderSchema, type EditOrderValues } from "@/lib/domain/validators";
import { updateOrderDetailsAction } from "@/lib/actions/orders";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from "@/components/ui/form";
import { RegionDatalist } from "@/components/shared/region-datalist";
import {
  Dialog,
  DialogContent,
  DialogDescription,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import type { Order, Region } from "@/types/database";

/**
 * Owner/Moderator correcting or updating any customer/order-detail field on
 * an existing order — a typo in the phone number, a wrong piece count, an
 * address correction, etc. Distribution (driver/factory) is reassigned
 * through ChangeDriverButton/ChangeFactoryButton instead, not here. See
 * updateOrderDetailsAction / update_order_details (migration 0021).
 */
export function EditOrderDialog({ order, regions }: { order: Order; regions: Region[] }) {
  const [open, setOpen] = useState(false);
  const [submitting, setSubmitting] = useState(false);
  const router = useRouter();
  const regionListId = useId();

  // order carries only region_id (the FK) — resolve it to the typed name
  // the text field now shows, from the same regions list already passed
  // in for the datalist suggestions.
  const currentRegionName = regions.find((r) => r.id === order.region_id)?.name ?? "";

  const form = useForm<EditOrderValues>({
    resolver: zodResolver(editOrderSchema),
    defaultValues: {
      customer_name: order.customer_name,
      customer_phone: order.customer_phone,
      customer_address: order.customer_address,
      customer_maps_url: order.customer_maps_url ?? "",
      region_name: currentRegionName,
      pieces_count: order.pieces_count,
      piece_details: order.piece_details ?? "",
      color: order.color ?? "",
      work_required: order.work_required ?? "",
      customer_notes: order.customer_notes ?? "",
    },
  });

  function onOpenChange(next: boolean) {
    if (next) {
      // Re-sync from the latest order prop each time the dialog opens, in
      // case it changed since the form was first mounted.
      form.reset({
        customer_name: order.customer_name,
        customer_phone: order.customer_phone,
        customer_address: order.customer_address,
        customer_maps_url: order.customer_maps_url ?? "",
        region_name: currentRegionName,
        pieces_count: order.pieces_count,
        piece_details: order.piece_details ?? "",
        color: order.color ?? "",
        work_required: order.work_required ?? "",
        customer_notes: order.customer_notes ?? "",
      });
    }
    setOpen(next);
  }

  async function onSubmit(values: EditOrderValues) {
    setSubmitting(true);
    const res = await updateOrderDetailsAction(order.id, values);
    setSubmitting(false);

    if (!res.ok) {
      toast.error(res.error);
      return;
    }

    toast.success("تم تعديل بيانات الأوردر");
    setOpen(false);
    router.refresh();
  }

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          <Pencil className="size-4" />
          تعديل بيانات الأوردر
        </Button>
      </DialogTrigger>
      <DialogContent className="max-h-[85vh] overflow-y-auto sm:max-w-lg">
        <DialogHeader>
          <DialogTitle>تعديل بيانات الأوردر {order.order_number}</DialogTitle>
          <DialogDescription>يمكن تعديل كل بيانات العميل والأوردر هنا. لا يشمل هذا المندوب أو المصنع المخصص.</DialogDescription>
        </DialogHeader>

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
                      <Input {...field} list={regionListId} placeholder="اكتب اسم المنطقة" />
                    </FormControl>
                    <RegionDatalist id={regionListId} regions={regions} />
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

            <DialogFooter>
              <Button type="button" variant="outline" onClick={() => setOpen(false)} disabled={submitting}>
                تراجع
              </Button>
              <Button type="submit" disabled={submitting}>
                {submitting && <Loader2 className="animate-spin" />}
                حفظ التعديلات
              </Button>
            </DialogFooter>
          </form>
        </Form>
      </DialogContent>
    </Dialog>
  );
}
