"use client";

import { useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { useRouter } from "next/navigation";
import { toast } from "sonner";
import { bootstrapOwnerSchema, type BootstrapOwnerValues } from "@/lib/domain/validators";
import { bootstrapOwnerAction } from "@/lib/actions/setup";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from "@/components/ui/form";
import { Loader2 } from "lucide-react";

export function SetupForm() {
  const router = useRouter();
  const [submitting, setSubmitting] = useState(false);

  const form = useForm<BootstrapOwnerValues>({
    resolver: zodResolver(bootstrapOwnerSchema),
    defaultValues: { full_name: "", phone: "", password: "", confirmPassword: "" },
  });

  async function onSubmit(values: BootstrapOwnerValues) {
    setSubmitting(true);
    const res = await bootstrapOwnerAction(values);
    setSubmitting(false);

    if (!res.ok) {
      toast.error("تعذر إنشاء الحساب", { description: res.error });
      return;
    }

    toast.success("تم إنشاء حساب صاحب النظام وتسجيل الدخول");
    // Straight to the Owner dashboard — bootstrapOwnerAction always creates
    // an owner, and the homepage no longer auto-redirects signed-in users
    // (see src/app/page.tsx), so this can't rely on "/" bouncing us there.
    router.replace("/owner");
    router.refresh();
  }

  return (
    <Form {...form}>
      <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4">
        <FormField
          control={form.control}
          name="full_name"
          render={({ field }) => (
            <FormItem>
              <FormLabel>الاسم الكامل</FormLabel>
              <FormControl>
                <Input {...field} />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />
        <FormField
          control={form.control}
          name="phone"
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
        <FormField
          control={form.control}
          name="password"
          render={({ field }) => (
            <FormItem>
              <FormLabel>كلمة المرور</FormLabel>
              <FormControl>
                <Input type="password" dir="ltr" {...field} />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />
        <FormField
          control={form.control}
          name="confirmPassword"
          render={({ field }) => (
            <FormItem>
              <FormLabel>تأكيد كلمة المرور</FormLabel>
              <FormControl>
                <Input type="password" dir="ltr" {...field} />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />
        <Button type="submit" className="w-full" disabled={submitting}>
          {submitting && <Loader2 className="animate-spin" />}
          إنشاء الحساب وتسجيل الدخول
        </Button>
      </form>
    </Form>
  );
}
