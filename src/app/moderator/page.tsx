import Link from "next/link";
import { getDashboardStats } from "@/lib/data/orders";
import { StatCard } from "@/components/shared/stat-card";
import { Button } from "@/components/ui/button";
import { PackagePlus, PackageCheck, Truck, Factory, Clock } from "lucide-react";

export default async function ModeratorDashboardPage() {
  const stats = await getDashboardStats();

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold">نظرة عامة</h1>
        <Button asChild size="sm">
          <Link href="/moderator/orders/new">
            <PackagePlus />
            أوردر جديد
          </Link>
        </Button>
      </div>

      <div className="stagger-children grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard label="إجمالي الأوردرات" value={stats.total_orders} icon={PackageCheck} />
        <StatCard label="جديدة (بانتظار التوزيع)" value={stats.new_orders} icon={PackagePlus} />
        <StatCard
          label="مع المندوبين"
          value={stats.assigned_orders + stats.collected_orders + stats.with_driver_orders}
          icon={Truck}
        />
        <StatCard label="داخل المصنع" value={stats.at_factory_orders} icon={Factory} />
        <StatCard label="جاهزة للتسليم" value={stats.ready_orders} icon={Clock} tone="warning" />
      </div>

      <div className="rounded-lg border bg-muted/40 p-4 text-sm text-muted-foreground">
        استخدم زر &quot;أوردر جديد&quot; لتسجيل أي طلب وارد عبر Messenger أو الهاتف. الأوردرات الواردة من الموقع تظهر تلقائيًا في
        قائمة الأوردرات وبإمكانك اقتراح مندوب لها بانتظار اعتماد المدير.
      </div>
    </div>
  );
}
