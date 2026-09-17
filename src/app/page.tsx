import Link from "next/link";
import { getCurrentProfile } from "@/lib/auth";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { HeroBackground } from "@/components/shared/hero-background";
import { BrandLogoFull } from "@/components/shared/brand-logo";
import { TrackOrderForm } from "@/components/track/track-order-form";
import { LogIn, LayoutDashboard, Building2, Truck, Factory, ShieldCheck } from "lucide-react";

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
    <main className="min-h-screen">
      {/* Hero: brand + the order-tracking field itself, right here on the
          homepage — a visitor doesn't have to click through to /track just
          to look something up. The photo/gradient only cover this section,
          not the whole page, so it doesn't stretch thin behind the
          about-us/login content further down. */}
      <section className="relative flex flex-col items-center gap-8 overflow-hidden p-6 py-14 sm:py-20">
        <HeroBackground />

        <div className="relative z-10 text-center space-y-3 animate-fade-in-up">
          <BrandLogoFull className="mx-auto h-24 w-auto drop-shadow-sm sm:h-28" />
          <span className="inline-flex items-center rounded-full bg-primary px-3 py-1 text-xs font-bold tracking-wide text-primary-foreground">
            إدارة وتوزيع الأوردرات
          </span>
          <p className="text-white/85">تابع أوردرك أدناه، أو سجّل دخولك كفريق عمل لإنشاء ومتابعة الأوردرات</p>
        </div>

        <Card
          className="relative z-10 w-full max-w-xl animate-fade-in-up border-0 bg-white shadow-2xl"
          style={{ animationDelay: "80ms" }}
        >
          <CardHeader>
            <CardTitle>تتبع أوردر</CardTitle>
            <CardDescription>أدخل رقم الأوردر ورقم هاتفك لمعرفة حالته الحالية</CardDescription>
          </CardHeader>
          <CardContent>
            <TrackOrderForm />
          </CardContent>
        </Card>
      </section>

      {/* About us — a short, honest description of what the system/service
          does. Replace with your own company copy whenever you're ready. */}
      <section className="mx-auto max-w-3xl px-6 py-14">
        <div className="mb-8 text-center space-y-2 animate-fade-in-up">
          <h2 className="text-2xl font-bold">من نحن</h2>
          <p className="text-muted-foreground">
            نربط بين العميل والمصنع من خلال فريق من المندوبين، بمتابعة دقيقة لكل خطوة من الاستلام إلى التسليم
          </p>
        </div>
        <div className="grid gap-4 sm:grid-cols-3">
          <Card className="animate-fade-in-up border-0 shadow-md" style={{ animationDelay: "80ms" }}>
            <CardContent className="flex flex-col items-center gap-2 pt-6 text-center">
              <div className="flex size-11 items-center justify-center rounded-xl bg-primary/15 text-primary">
                <Truck className="size-5" />
              </div>
              <p className="font-semibold">توزيع منظم</p>
              <p className="text-sm text-muted-foreground">مندوبون مخصصون لكل منطقة لاستلام وتسليم الأوردرات بسرعة</p>
            </CardContent>
          </Card>
          <Card className="animate-fade-in-up border-0 shadow-md" style={{ animationDelay: "150ms" }}>
            <CardContent className="flex flex-col items-center gap-2 pt-6 text-center">
              <div className="flex size-11 items-center justify-center rounded-xl bg-primary/15 text-primary">
                <Factory className="size-5" />
              </div>
              <p className="font-semibold">تنسيق مع المصانع</p>
              <p className="text-sm text-muted-foreground">تتبع كل أوردر من دخوله المصنع وحتى جاهزيته للتسليم</p>
            </CardContent>
          </Card>
          <Card className="animate-fade-in-up border-0 shadow-md" style={{ animationDelay: "220ms" }}>
            <CardContent className="flex flex-col items-center gap-2 pt-6 text-center">
              <div className="flex size-11 items-center justify-center rounded-xl bg-primary/15 text-primary">
                <ShieldCheck className="size-5" />
              </div>
              <p className="font-semibold">تسليم موثّق</p>
              <p className="text-sm text-muted-foreground">كود تأكيد لكل عملية تسليم، وسجل كامل لحركة الأوردر أولًا بأول</p>
            </CardContent>
          </Card>
        </div>
      </section>

      {/* Staff sign-in — for the team (Moderator/Manager/drivers/factories),
          placed last so the customer-facing content above it comes first. */}
      <section className="mx-auto max-w-xl px-6 pb-16">
        {dashboardHref ? (
          <Card className="animate-fade-in-up border-0 bg-primary text-primary-foreground shadow-xl">
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
          <Card className="animate-fade-in-up border-0 bg-primary text-primary-foreground shadow-xl">
            <CardHeader>
              <div className="flex size-12 items-center justify-center rounded-xl bg-primary-foreground/15 shadow-sm">
                <LogIn className="size-6" />
              </div>
              <CardTitle className="text-primary-foreground">تسجيل دخول فريق العمل</CardTitle>
              <CardDescription className="text-primary-foreground/80">
                للموديريتور والمدير والمندوبين والمصانع — من هنا يتم إنشاء ومتابعة الأوردرات
              </CardDescription>
            </CardHeader>
            <CardContent className="space-y-2">
              <Button asChild variant="secondary" className="w-full">
                <Link href="/login">
                  <LogIn className="size-4" />
                  تسجيل الدخول
                </Link>
              </Button>
              <p className="flex items-center justify-center gap-1.5 text-center text-xs text-primary-foreground/70">
                <Building2 className="size-3.5" />
                مندوب أو مصنع؟ استخدم نفس الزر أعلاه بنفس رقم هاتفك
              </p>
            </CardContent>
          </Card>
        )}
      </section>
    </main>
  );
}
