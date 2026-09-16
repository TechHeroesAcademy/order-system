import Link from "next/link";
import { getCurrentProfile } from "@/lib/auth";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { ShippingIllustration } from "@/components/home/shipping-illustration";
import { Search, LogIn, LayoutDashboard } from "lucide-react";

const ROLE_HOME: Record<string, string> = {
  owner: "/owner",
  moderator: "/moderator",
  driver: "/driver",
  factory: "/factory",
};

const ROLE_LABEL_AR: Record<string, string> = {
  owner: "مدير",
  moderator: "المشرف",
  driver: "المندوب",
  factory: "المصنع",
};

export default async function HomePage() {
  // This page used to redirect a signed-in visitor straight to their role's
  // dashboard, which meant a plain browser refresh (or just typing the site
  // address) on "/" never actually showed the homepage — it always bounced
  // onward. The homepage now always renders; a signed-in visitor gets a
  // one-click "go to my dashboard" card instead of an automatic redirect.
  // Login (and first-run Owner setup) send people straight to their
  // dashboard on their own, so this doesn't add an extra step there.
  const profile = await getCurrentProfile();
  const dashboardHref = profile?.is_active ? (ROLE_HOME[profile.role] ?? null) : null;

  return (
    <main className="relative flex min-h-screen flex-col items-center justify-center gap-8 overflow-hidden p-6">
      {/* decorative cartoon background — purely visual, see the component */}
      <ShippingIllustration className="pointer-events-none absolute inset-x-0 bottom-0 h-72 w-full select-none opacity-95 sm:h-96 md:h-[30rem] lg:h-[36rem]" />
      <div
        aria-hidden="true"
        className="pointer-events-none absolute inset-x-0 top-0 h-40 bg-gradient-to-b from-background to-transparent"
      />

      <div className="relative z-10 text-center space-y-2 animate-fade-in-up">
        <h1 className="text-2xl font-bold">شركة المجد</h1>
        <p className="text-muted-foreground">تابع حالة أوردر موجود، أو سجّل دخولك كفريق عمل لإنشاء ومتابعة الأوردرات</p>
      </div>

      <div className="relative z-10 grid w-full max-w-3xl gap-4 sm:grid-cols-2">
        {dashboardHref ? (
          <Card
            className="animate-fade-in-up border-2 bg-primary text-primary-foreground transition-[transform,box-shadow] hover:-translate-y-0.5 hover:shadow-lg"
            style={{ animationDelay: "80ms" }}
          >
            <CardHeader>
              <div className="flex size-12 items-center justify-center rounded-xl bg-primary-foreground/15 shadow-sm">
                <LayoutDashboard className="size-6" />
              </div>
              <CardTitle className="text-primary-foreground">لوحة التحكم</CardTitle>
              <CardDescription className="text-primary-foreground/80">
                أهلاً {profile?.full_name} — أنت مسجّل الدخول بصفة {ROLE_LABEL_AR[profile!.role] ?? profile!.role}
              </CardDescription>
            </CardHeader>
            <CardContent>
              <Button asChild variant="secondary" className="w-full">
                <Link href={dashboardHref}>الذهاب إلى لوحة التحكم</Link>
              </Button>
            </CardContent>
          </Card>
        ) : (
          // Order creation now only happens through a signed-in team member
          // (Owner/Moderator, at /moderator/orders/new) instead of an open
          // public form — this card replaces the old "إنشاء أوردر" one.
          <Card
            className="animate-fade-in-up border-2 bg-primary text-primary-foreground transition-[transform,box-shadow] hover:-translate-y-0.5 hover:shadow-lg"
            style={{ animationDelay: "80ms" }}
          >
            <CardHeader>
              <div className="flex size-12 items-center justify-center rounded-xl bg-primary-foreground/15 shadow-sm">
                <LogIn className="size-6" />
              </div>
              <CardTitle className="text-primary-foreground">تسجيل دخول فريق العمل</CardTitle>
              <CardDescription className="text-primary-foreground/80">
                للموديريتور والمدير والمندوبين والمصنع — من هنا يتم إنشاء ومتابعة الأوردرات
              </CardDescription>
            </CardHeader>
            <CardContent>
              <Button asChild variant="secondary" className="w-full">
                <Link href="/login">تسجيل الدخول</Link>
              </Button>
            </CardContent>
          </Card>
        )}

        <Card
          className="animate-fade-in-up border-2 transition-[transform,box-shadow] hover:-translate-y-0.5 hover:shadow-lg"
          style={{ animationDelay: "160ms" }}
        >
          <CardHeader>
            <div className="flex size-12 items-center justify-center rounded-xl bg-primary shadow-sm">
              <Search className="size-6 text-primary-foreground" />
            </div>
            <CardTitle>تتبع أوردر</CardTitle>
            <CardDescription>أدخل رقم الأوردر ورقم هاتفك لمعرفة حالته الحالية</CardDescription>
          </CardHeader>
          <CardContent>
            <Button asChild variant="outline" className="w-full">
              <Link href="/track">تتبع الأوردر</Link>
            </Button>
          </CardContent>
        </Card>
      </div>
    </main>
  );
}
