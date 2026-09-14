"use client";

import { Suspense, useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { useRouter, useSearchParams } from "next/navigation";
import { toast } from "sonner";
import { createClient } from "@/lib/supabase/client";
import { loginSchema, type LoginValues } from "@/lib/domain/validators";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from "@/components/ui/form";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Loader2 } from "lucide-react";

export default function LoginPage() {
  return (
    <Suspense fallback={null}>
      <LoginForm />
    </Suspense>
  );
}

function LoginForm() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const [submitting, setSubmitting] = useState(false);
  const inactiveError = searchParams.get("error") === "account_inactive";

  const form = useForm<LoginValues>({
    resolver: zodResolver(loginSchema),
    defaultValues: { email: "", password: "" },
  });

  async function onSubmit(values: LoginValues) {
    setSubmitting(true);
    const supabase = createClient();
    const { error } = await supabase.auth.signInWithPassword(values);
    setSubmitting(false);

    if (error) {
      toast.error("فشل تسجيل الدخول", { description: "تأكد من البريد الإلكتروني وكلمة المرور" });
      return;
    }

    toast.success("تم تسجيل الدخول بنجاح");
    router.replace(searchParams.get("next") || "/");
    router.refresh();
  }

  return (
    <main className="flex min-h-screen items-center justify-center p-6">
      <Card className="w-full max-w-sm">
        <CardHeader>
          <CardTitle>تسجيل دخول فريق العمل</CardTitle>
          <CardDescription>للـ Owner والموديريتور والمندوبين والمصنع</CardDescription>
        </CardHeader>
        <CardContent>
          {inactiveError && (
            <Alert variant="destructive" className="mb-4">
              <AlertDescription>هذا الحساب غير مفعّل. تواصل مع صاحب النظام.</AlertDescription>
            </Alert>
          )}
          <Form {...form}>
            <form onSubmit={form.handleSubmit(onSubmit)} className="space-y-4">
              <FormField
                control={form.control}
                name="email"
                render={({ field }) => (
                  <FormItem>
                    <FormLabel>البريد الإلكتروني</FormLabel>
                    <FormControl>
                      <Input type="email" dir="ltr" placeholder="name@example.com" {...field} />
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
              <Button type="submit" className="w-full" disabled={submitting}>
                {submitting && <Loader2 className="animate-spin" />}
                تسجيل الدخول
              </Button>
            </form>
          </Form>
        </CardContent>
      </Card>
    </main>
  );
}
