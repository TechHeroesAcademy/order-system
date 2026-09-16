import Link from "next/link";
import { ownerExists } from "@/lib/actions/setup";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { SetupForm } from "@/components/auth/setup-form";
import { ShippingIllustration } from "@/components/home/shipping-illustration";

export default async function SetupPage() {
  const alreadySetUp = await ownerExists();

  return (
    <main className="relative flex min-h-screen items-center justify-center overflow-hidden p-6">
      <ShippingIllustration className="pointer-events-none absolute inset-x-0 bottom-0 h-40 w-full select-none opacity-70 sm:h-56 md:h-64" />
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 top-0 h-32 bg-gradient-to-b from-background to-transparent"
      />

      <Card className="relative z-10 w-full max-w-sm">
        <CardHeader>
          <CardTitle>إعداد حساب صاحب النظام</CardTitle>
          <CardDescription>خطوة تُنفَّذ مرة واحدة فقط عند أول استخدام للنظام</CardDescription>
        </CardHeader>
        <CardContent>
          {alreadySetUp ? (
            <div className="space-y-4 text-center">
              <p className="text-sm text-muted-foreground">
                تم إعداد حساب صاحب النظام بالفعل. سجّل الدخول برقم هاتفك من صفحة الدخول.
              </p>
              <Button asChild className="w-full">
                <Link href="/login">الذهاب لصفحة الدخول</Link>
              </Button>
            </div>
          ) : (
            <SetupForm />
          )}
        </CardContent>
      </Card>
    </main>
  );
}
