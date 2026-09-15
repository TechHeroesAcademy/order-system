import Link from "next/link";
import { redirect } from "next/navigation";
import { getCurrentProfile } from "@/lib/auth";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { PackagePlus, Search, LogIn } from "lucide-react";

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
        <p className="text-muted-foreground">أنشئ أوردر جديد أو تابع حالة أوردر موجود بالفعل</p>
      </div>

      <div className="grid w-full max-w-3xl gap-4 sm:grid-cols-2">
        <Card
          className="animate-fade-in-up border-2 transition-[transform,box-shadow] hover:-translate-y-0.5 hover:shadow-lg"
          style={{ animationDelay: "80ms" }}
        >
          <CardHeader>
            <div className="flex size-12 items-center justify-center rounded-xl bg-primary shadow-sm">
              <PackagePlus className="size-6 text-primary-foreground" />
            </div>
            <CardTitle>إنشاء أوردر جديد</CardTitle>
            <CardDescription>أدخل بيانات طلبك وسيتم التواصل معك لتنفيذه</CardDescription>
          </CardHeader>
          <CardContent>
            <Button asChild className="w-full">
              <Link href="/order/new">إنشاء أوردر</Link>
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
            <Button asChild variant="secondary" className="w-full">
              <Link href="/track">تتبع الأوردر</Link>
            </Button>
          </CardContent>
        </Card>
      </div>

      <Button asChild variant="ghost" size="sm" className="animate-fade-in-up" style={{ animationDelay: "220ms" }}>
        <Link href="/login">
          <LogIn className="size-4" />
          تسجيل دخول فريق العمل
        </Link>
      </Button>
    </main>
  );
}
