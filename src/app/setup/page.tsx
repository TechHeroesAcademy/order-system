import Link from "next/link";
import { ownerExists } from "@/lib/actions/setup";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { SetupForm } from "@/components/auth/setup-form";

export default async function SetupPage() {
  const alreadySetUp = await ownerExists();

  return (
    <main className="flex min-h-screen items-center justify-center p-6">
      <Card className="w-full max-w-sm">
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
