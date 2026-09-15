import Link from "next/link";
import { redirect } from "next/navigation";
import { getCurrentProfile } from "@/lib/auth";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { Search, LogIn } from "lucide-react";

const ROLE_HOME: Record<string, string> = {
  owner: "/owner",
  moderator: "/moderator",
  driver: "/driver",
  factory: "/factory",
};

export default async function HomePage() {
  const profile = await getCurrentProfile();
  if (profile?.is_active) {
    redirect(ROLE_HOME[profile.role] ?? "/login");
  }

  return (
    <main className="flex min-h-screen flex-col items-center justify-center gap-8 p-6">
      <div className="text-center space-y-2 animate-fade-in-up">
        <h1 className="text-2xl font-bold">شركة المجد</h1>
        <p className="text-muted-foreground">تابع حالة أوردر موجود، أو سجّل دخولك كفريق عمل لإنشاء ومتابعة الأوردرات</p>
      </div>

      <div className="grid w-full max-w-3xl gap-4 sm:grid-cols-2">
        {/* Order creation now only happens through a signed-in team member
            (Owner/Moderator, at /moderator/orders/new) instead of an open
            public form — this card replaces the old "إنشاء أوردر" one. */}
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
              للموديريتور وOwner والمندوبين والمصنع — من هنا يتم إنشاء ومتابعة الأوردرات
            </CardDescription>
          </CardHeader>
          <CardContent>
            <Button asChild variant="secondary" className="w-full">
              <Link href="/login">تسجيل الدخول</Link>
            </Button>
          </CardContent>
        </Card>

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
