import Link from "next/link";
import { getDashboardStats, getDelayedOrders } from "@/lib/data/orders";
import { StatCard } from "@/components/shared/stat-card";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import { EmptyState } from "@/components/shared/empty-state";
import { formatHours } from "@/lib/domain/format";
import {
  PackagePlus,
  Truck,
  Factory,
  PackageCheck,
  AlertTriangle,
  Clock,
  CheckCircle2,
} from "lucide-react";

export default async function OwnerDashboardPage() {
  const [stats, delayed] = await Promise.all([getDashboardStats(), getDelayedOrders()]);

  return (
    <div className="space-y-6">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold">نظرة عامة</h1>
        <Button asChild size="sm" variant="outline">
          <Link href="/moderator/orders/new">
            <PackagePlus />
            أوردر جديد (Messenger)
          </Link>
        </Button>
      </div>

      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard label="إجمالي الأوردرات" value={stats.total_orders} icon={PackageCheck} />
        <StatCard label="جديدة (بانتظار التوزيع)" value={stats.new_orders} icon={PackagePlus} />
        <StatCard label="مع المندوبين" value={stats.assigned_orders + stats.collected_orders + stats.with_driver_orders} icon={Truck} />
        <StatCard label="داخل المصنع" value={stats.at_factory_orders} icon={Factory} />
        <StatCard label="جاهزة للتسليم" value={stats.ready_orders} icon={Clock} tone="warning" />
        <StatCard label="تم التسليم" value={stats.delivered_orders} icon={CheckCircle2} tone="success" />
        <StatCard label="رفض الاستلام" value={stats.refused_orders} tone="destructive" />
        <StatCard label="أوردرات متأخرة" value={stats.delayed_orders} icon={AlertTriangle} tone="warning" />
      </div>

      <Card>
        <CardHeader className="flex-row items-center justify-between">
          <CardTitle className="flex items-center gap-2 text-base">
            <AlertTriangle className="size-4 text-warning" />
            الأوردرات المتأخرة
          </CardTitle>
          <Button asChild size="sm" variant="ghost">
            <Link href="/owner/orders?status=all">عرض كل الأوردرات</Link>
          </Button>
        </CardHeader>
        <CardContent>
          {delayed.length === 0 ? (
            <EmptyState icon={CheckCircle2} title="لا يوجد أوردرات متأخرة حاليًا" />
          ) : (
            <ul className="divide-y">
              {delayed.slice(0, 8).map((o) => (
                <li key={o.id} className="flex items-center justify-between py-2">
                  <div>
                    <Link href={`/owner/orders/${o.id}`} className="text-sm font-medium hover:underline">
                      {o.order_number}
                    </Link>
                    <p className="text-xs text-muted-foreground">
                      {o.customer_name} · {o.region_name ?? "—"} · {o.driver_name ?? "بدون مندوب"}
                    </p>
                  </div>
                  <span className="text-sm text-warning">{formatHours(o.hours_open)}</span>
                </li>
              ))}
            </ul>
          )}
        </CardContent>
      </Card>
    </div>
  );
}
