"use client";

import { Suspense, useState } from "react";
import { useForm } from "react-hook-form";
import { zodResolver } from "@hookform/resolvers/zod";
import { useRouter, useSearchParams } from "next/navigation";
import { toast } from "sonner";
import { phoneLookupSchema, setInitialPasswordSchema, phoneLoginSchema } from "@/lib/domain/validators";
import { checkPhoneAction, setInitialPasswordAction, phoneLoginAction } from "@/lib/actions/staff-auth";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Form, FormControl, FormField, FormItem, FormLabel, FormMessage } from "@/components/ui/form";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Loader2, ArrowRight } from "lucide-react";

export function LoginPageClient() {
  return (
    <Suspense fallback={null}>
      <LoginPageInner />
    </Suspense>
  );
}

function LoginPageInner() {
  const searchParams = useSearchParams();
  const inactiveError = searchParams.get("error") === "account_inactive";

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
          <PhoneLoginFlow />
        </CardContent>
      </Card>
    </main>
  );
}

/**
 * Two steps: enter phone number, then either create a password (first-ever
 * login) or enter the one already set — checkPhoneAction tells us which
 * without ever sending the account's real (internal, synthetic) email to
 * the browser. This is the only login path in the system — no email/password
 * form exists anywhere, including for the Owner (see /setup for bootstrap).
 */
function PhoneLoginFlow() {
  const router = useRouter();
  const searchParams = useSearchParams();
  const [stage, setStage] = useState<"phone" | "create" | "enter">("phone");
  const [phone, setPhone] = useState("");
  const [submitting, setSubmitting] = useState(false);

  const phoneForm = useForm<{ phone: string }>({
    resolver: zodResolver(phoneLookupSchema),
    defaultValues: { phone: "" },
  });

  const createForm = useForm({
    resolver: zodResolver(setInitialPasswordSchema),
    defaultValues: { phone: "", password: "", confirmPassword: "" },
  });

  const enterForm = useForm({
    resolver: zodResolver(phoneLoginSchema),
    defaultValues: { phone: "", password: "" },
  });

  async function onCheckPhone(values: { phone: string }) {
    setSubmitting(true);
    const res = await checkPhoneAction(values);
    setSubmitting(false);
    if (!res.ok) {
      phoneForm.setError("phone", { message: res.error });
      return;
    }
    setPhone(values.phone);
    if (res.data.needsPasswordSetup) {
      createForm.setValue("phone", values.phone);
      setStage("create");
    } else {
      enterForm.setValue("phone", values.phone);
      setStage("enter");
    }
  }

  async function onCreatePassword(values: { phone: string; password: string; confirmPassword: string }) {
    setSubmitting(true);
    const res = await setInitialPasswordAction(values);
    setSubmitting(false);
    if (!res.ok) {
      toast.error("تعذر إنشاء كلمة المرور", { description: res.error });
      return;
    }
    toast.success("تم إنشاء كلمة المرور وتسجيل الدخول");
    // Straight to the role's own dashboard — the homepage no longer
    // auto-redirects signed-in visitors (it always shows the main page now,
    // per request), so login can't rely on "/" bouncing us there anymore.
    router.replace(searchParams.get("next") || `/${res.data.role}`);
    router.refresh();
  }

  async function onEnterPassword(values: { phone: string; password: string }) {
    setSubmitting(true);
    const res = await phoneLoginAction(values);
    setSubmitting(false);
    if (!res.ok) {
      toast.error("فشل تسجيل الدخول", { description: res.error });
      return;
    }
    toast.success("تم تسجيل الدخول بنجاح");
    router.replace(searchParams.get("next") || `/${res.data.role}`);
    router.refresh();
  }

  function backToPhone() {
    setStage("phone");
    createForm.reset({ phone: "", password: "", confirmPassword: "" });
    enterForm.reset({ phone: "", password: "" });
  }

  if (stage === "phone") {
    return (
      <Form {...phoneForm}>
        <form onSubmit={phoneForm.handleSubmit(onCheckPhone)} className="space-y-4">
          <FormField
            control={phoneForm.control}
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
          <Button type="submit" className="w-full" disabled={submitting}>
            {submitting && <Loader2 className="animate-spin" />}
            متابعة
          </Button>
        </form>
      </Form>
    );
  }

  if (stage === "create") {
    return (
      <Form {...createForm}>
        <form onSubmit={createForm.handleSubmit(onCreatePassword)} className="space-y-4">
          <p className="text-sm text-muted-foreground">
            أول تسجيل دخول لك — أنشئ كلمة مرور لحسابك ({phone})
          </p>
          <FormField
            control={createForm.control}
            name="password"
            render={({ field }) => (
              <FormItem>
                <FormLabel>كلمة المرور الجديدة</FormLabel>
                <FormControl>
                  <Input type="password" dir="ltr" {...field} />
                </FormControl>
                <FormMessage />
              </FormItem>
            )}
          />
          <FormField
            control={createForm.control}
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
            إنشاء كلمة المرور وتسجيل الدخول
          </Button>
          <Button type="button" variant="ghost" className="w-full" onClick={backToPhone} disabled={submitting}>
            <ArrowRight className="size-4" />
            رقم هاتف آخر
          </Button>
        </form>
      </Form>
    );
  }

  return (
    <Form {...enterForm}>
      <form onSubmit={enterForm.handleSubmit(onEnterPassword)} className="space-y-4">
        <p className="text-sm text-muted-foreground">{phone}</p>
        <FormField
          control={enterForm.control}
          name="password"
          render={({ field }) => (
            <FormItem>
              <FormLabel>كلمة المرور</FormLabel>
              <FormControl>
                <Input type="password" dir="ltr" autoFocus {...field} />
              </FormControl>
              <FormMessage />
            </FormItem>
          )}
        />
        <Button type="submit" className="w-full" disabled={submitting}>
          {submitting && <Loader2 className="animate-spin" />}
          تسجيل الدخول
        </Button>
        <Button type="button" variant="ghost" className="w-full" onClick={backToPhone} disabled={submitting}>
          <ArrowRight className="size-4" />
          رقم هاتف آخر
        </Button>
      </form>
    </Form>
  );
}
