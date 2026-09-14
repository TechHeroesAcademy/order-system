import {
  getDailyReport,
  getMonthlyReport,
  getDriverPerformance,
  getTopRegions,
} from "@/lib/data/orders";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import {
  Table,
  TableBody,
  TableCell,
  TableHead,
  TableHeader,
  TableRow,
} from "@/components/ui/table";
import { StatCard } from "@/components/shared/stat-card";
import { formatHours, formatPercent } from "@/lib/domain/format";
import { EmptyState } from "@/components/shared/empty-state";
import { BarChart3 } from "lucide-react";

export default async function ReportsPage() {
  const [daily, monthly, driverPerf, topRegions] = await Promise.all([
    getDailyReport(),
    getMonthlyReport(),
    getDriverPerformance(),
    getTopRegions(),
  ]);

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-bold">التقارير والإحصائيات</h1>

      <Tabs defaultValue="daily">
        <TabsList>
          <TabsTrigger value="daily">تقرير اليوم</TabsTrigger>
          <TabsTrigger value="monthly">تقرير الشهر</TabsTrigger>
          <TabsTrigger value="drivers">أداء المندوبين</TabsTrigger>
          <TabsTrigger value="regions">المناطق الأكثر طلبًا</TabsTrigger>
        </TabsList>

        <TabsContent value="daily" className="space-y-3 pt-4">
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-5">
            <StatCard label="أوردرات جديدة" value={daily.new_orders} />
            <StatCard label="تم استلامها من العملاء" value={daily.collected_orders} />
            <StatCard label="دخلت المصنع" value={daily.entered_factory} />
            <StatCard label="تم تسليمها" value={daily.delivered_orders} tone="success" />
            <StatCard label="متأخرة" value={daily.delayed_orders} tone="warning" />
          </div>
        </TabsContent>

        <TabsContent value="monthly" className="space-y-3 pt-4">
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
            <StatCard label="إجمالي الأوردرات هذا الشهر" value={monthly.total_orders} />
            <StatCard label="إجمالي القطع" value={monthly.total_pieces} />
            <StatCard label="أوردرات مكتملة" value={monthly.completed_orders} tone="success" />
            <StatCard label="أوردرات متأخرة" value={monthly.delayed_orders} tone="warning" />
            <StatCard label="متوسط مدة التنفيذ" value={formatHours(monthly.avg_completion_hours)} />
            <StatCard label="نسبة التسليم في الوقت" value={formatPercent(monthly.on_time_rate)} tone="success" />
          </div>
        </TabsContent>

        <TabsContent value="drivers" className="pt-4">
          <Card>
            <CardContent className="p-0">
              {driverPerf.length === 0 ? (
                <EmptyState icon={BarChart3} title="لا يوجد مندوبون بعد" />
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>المندوب</TableHead>
                      <TableHead>الإجمالي</TableHead>
                      <TableHead>مكتملة</TableHead>
                      <TableHead>حالية</TableHead>
                      <TableHead>متأخرة</TableHead>
                      <TableHead>رفض استلام</TableHead>
                      <TableHead>متوسط مدة التنفيذ</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {driverPerf.map((d) => (
                      <TableRow key={d.driver_id}>
                        <TableCell className="font-medium">{d.full_name}</TableCell>
                        <TableCell>{d.total_orders}</TableCell>
                        <TableCell>{d.completed_orders}</TableCell>
                        <TableCell>{d.active_orders}</TableCell>
                        <TableCell className={d.delayed_orders > 0 ? "text-warning" : undefined}>
                          {d.delayed_orders}
                        </TableCell>
                        <TableCell className={d.refusal_count > 0 ? "text-destructive" : undefined}>
                          {d.refusal_count}
                        </TableCell>
                        <TableCell>{formatHours(d.avg_completion_hours)}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="regions" className="pt-4">
          <Card>
            <CardHeader>
              <CardTitle className="text-base">عدد الأوردرات حسب المنطقة</CardTitle>
            </CardHeader>
            <CardContent className="space-y-2">
              {topRegions.map((r) => (
                <div key={r.region_name} className="flex items-center gap-3">
                  <span className="w-32 shrink-0 text-sm">{r.region_name}</span>
                  <div className="h-2 flex-1 overflow-hidden rounded-full bg-muted">
                    <div
                      className="h-full bg-primary"
                      style={{
                        width: `${Math.min(100, (r.order_count / (topRegions[0]?.order_count || 1)) * 100)}%`,
                      }}
                    />
                  </div>
                  <span className="w-10 text-end text-sm tabular-nums text-muted-foreground">{r.order_count}</span>
                </div>
              ))}
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>
    </div>
  );
}
