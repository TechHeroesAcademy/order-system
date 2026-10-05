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
  factory: "/login",
};

const ROLE_LABEL_AR: Record<string, string> = {
  owner: "مدير",
  moderator: "المشرف",
  driver: "المندوب",
  factory: "المصنع",
};

export default async function HomePage() {
  const profile = await getCurrentProfile();
  const dashboardHref = profile?.is_active ? (ROLE_HOME[profile.role] ?? null) : null;

  return (
    <main className="min-h-screen">
      <section className="relative flex flex-col items-center gap-8 overflow-hidden p-6 py-14 sm:py-20">
        <HeroBackground />

        <div className="relative z-10 text-center space-y-3 animate-fade-in-up">
          <BrandLogoFull className="mx-auto h-24 w-auto drop-shadow-sm sm:h-28" />
          <span className="inline-flex items-center rounded-full bg-primary px-3 py-1 text-xs font-bold tracking-wide text-primary-foreground">
            تجديد أواني الطهي
          </span>
          <p className="text-white/85">
            تابع حالة تجديد إناءك أدناه، أو سجّل دخولك كفريق عمل لإنشاء ومتابعة الأوردرات
          </p>
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

      <section className="mx-auto max-w-3xl px-6 py-14">
        <div className="mb-8 text-center space-y-2 animate-fade-in-up">
          <h2 className="text-2xl font-bold">من نحن</h2>
          <p className="text-muted-foreground">
            نُعيد الحياة لأواني الطهي القديمة بطلاء جديد وجودة مضمونة — من استلامها من عندك، وحتى تجديدها في
            مصانعنا وتسليمها إليك من جديد
          </p>
        </div>
        <div className="grid gap-4 sm:grid-cols-3">
          <Card className="animate-fade-in-up border-0 shadow-md" style={{ animationDelay: "80ms" }}>
            <CardContent className="flex flex-col items-center gap-2 pt-6 text-center">
              <div className="flex size-11 items-center justify-center rounded-xl bg-primary/15 text-primary">
                <Truck className="size-5" />
              </div>
              <p className="font-semibold">تجميع من عندك</p>
              <p className="text-sm text-muted-foreground">مندوبون مخصصون لكل منطقة يستلمون الأواني من عندك بسرعة</p>
            </CardContent>
          </Card>
          <Card className="animate-fade-in-up border-0 shadow-md" style={{ animationDelay: "150ms" }}>
            <CardContent className="flex flex-col items-center gap-2 pt-6 text-center">
              <div className="flex size-11 items-center justify-center rounded-xl bg-primary/15 text-primary">
                <Factory className="size-5" />
              </div>
              <p className="font-semibold">تجديد في المصنع</p>
              <p className="text-sm text-muted-foreground">طلاء جديد وجودة مضمونة في مصانعنا بالقاهرة والإسكندرية</p>
            </CardContent>
          </Card>
          <Card className="animate-fade-in-up border-0 shadow-md" style={{ animationDelay: "220ms" }}>
            <CardContent className="flex flex-col items-center gap-2 pt-6 text-center">
              <div className="flex size-11 items-center justify-center rounded-xl bg-primary/15 text-primary">
                <ShieldCheck className="size-5" />
              </div>
              <p className="font-semibold">تسليم موثّق</p>
              <p className="text-sm text-muted-foreground">كود تأكيد لكل عملية تسليم، وسجل كامل لحركة إناءك أولًا بأول</p>
            </CardContent>
          </Card>
        </div>
      </section>

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
                للمدير والموديريتور والمندوبين — من هنا يتم إنشاء ومتابعة الأوردرات
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
                مندوب؟ استخدم نفس الزر أعلاه بنفس رقم هاتفك
              </p>
            </CardContent>
          </Card>
        )}
      </section>
    </main>
  );
}
