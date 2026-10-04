import Link from "next/link";
import { ownerExists } from "@/lib/actions/setup";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { SetupForm } from "@/components/auth/setup-form";
import { HeroBackground } from "@/components/shared/hero-background";

/**
 * Rendered per request, not at build time.
 *
 * This page's content is a question about the database — does an owner
 * exist yet — and without this Next prerenders it as static HTML and bakes
 * in whatever the answer was during `next build`, where there is no database
 * at all. It then serves that forever.
 *
 * Which way it broke depended on how ownerExists() handled the build-time
 * failure: it currently fails closed, so a brand-new system was served
 * "تم إعداد حساب المدير بالفعل" and the owner could never be created. Before
 * that it failed open, so a configured system kept offering the bootstrap
 * form to anyone who visited. The second is not a security hole —
 * bootstrapOwnerAction re-checks, and bootstrap_owner() in the database
 * takes a row lock and refuses — but it is a confusing page either way.
 */
export const dynamic = "force-dynamic";

export default async function SetupPage() {
  const alreadySetUp = await ownerExists();

  return (
    <main className="relative flex min-h-screen items-center justify-center overflow-hidden p-6">
      <HeroBackground />

      <Card className="relative z-10 w-full max-w-sm border-0 bg-white shadow-2xl">
        <CardHeader>
          <CardTitle>إعداد حساب المدير</CardTitle>
          <CardDescription>خطوة تُنفَّذ مرة واحدة فقط عند أول استخدام للنظام</CardDescription>
        </CardHeader>
        <CardContent>
          {alreadySetUp ? (
            <div className="space-y-4 text-center">
              <p className="text-sm text-muted-foreground">
                تم إعداد حساب المدير بالفعل. سجّل الدخول برقم هاتفك من صفحة الدخول.
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
