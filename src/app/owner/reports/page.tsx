import {
  getDailyReport,
  getMonthlyReport,
  getDriverPerformance,
  getTopRegions,
  getDelayedOrders,
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
import { OrderStatusBadge } from "@/components/orders/order-status-badge";
import { BarChart3, TrendingUp, TrendingDown, Minus, AlertTriangle } from "lucide-react";
import { BarList } from "@/components/reports/bar-list";
import { RadialStat } from "@/components/reports/radial-stat";

export default async function ReportsPage() {
  const [daily, monthly, driverPerf, topRegions, delayedOrders] = await Promise.all([
    getDailyReport(),
    getMonthlyReport(),
    getDriverPerformance(),
    getTopRegions(),
    getDelayedOrders(),
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
          <TabsTrigger value="delayed">الأوردرات المتأخرة</TabsTrigger>
        </TabsList>

        <TabsContent value="daily" className="space-y-3 pt-4">
          <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
            <StatCard label="أوردرات جديدة" value={daily.new_orders} />
            <StatCard label="تم استلامها من العملاء" value={daily.collected_orders} />
            <StatCard label="دخلت المصنع اليوم" value={daily.entered_factory} />
            <StatCard label="خرجت من المصنع اليوم" value={daily.exited_factory} />
            <StatCard label="داخل المصنع حاليًا" value={daily.in_factory_now} />
            <StatCard label="جاهزة للتسليم حاليًا" value={daily.ready_now} tone="warning" />
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

          <Card>
            <CardHeader>
              <CardTitle className="text-base">مقارنة بالشهر السابق</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-wrap items-center gap-6">
              <div>
                <p className="text-xs text-muted-foreground">هذا الشهر</p>
                <p className="text-xl font-bold tabular-nums">{monthly.total_orders}</p>
              </div>
              <div>
                <p className="text-xs text-muted-foreground">الشهر السابق</p>
                <p className="text-xl font-bold tabular-nums">{monthly.prev_total_orders}</p>
              </div>
              <div className="flex items-center gap-1.5">
                {monthly.orders_change_percent === null ? (
                  <Minus className="size-4 text-muted-foreground" />
                ) : monthly.orders_change_percent > 0 ? (
                  <TrendingUp className="size-4 text-success" />
                ) : monthly.orders_change_percent < 0 ? (
                  <TrendingDown className="size-4 text-destructive" />
                ) : (
                  <Minus className="size-4 text-muted-foreground" />
                )}
                <span
                  className={
                    monthly.orders_change_percent === null || monthly.orders_change_percent === 0
                      ? "text-muted-foreground"
                      : monthly.orders_change_percent > 0
                        ? "text-success"
                        : "text-destructive"
                  }
                >
                  {monthly.orders_change_percent === null ? "لا يوجد بيانات كافية" : formatPercent(monthly.orders_change_percent)}
                </span>
              </div>
            </CardContent>
          </Card>

          <Card>
            <CardHeader>
              <CardTitle className="text-base">نظرة عامة</CardTitle>
            </CardHeader>
            <CardContent className="flex flex-wrap justify-around gap-6">
              <RadialStat
                label="نسبة الأوردرات المكتملة"
                percent={monthly.total_orders > 0 ? (monthly.completed_orders / monthly.total_orders) * 100 : 0}
                colorClassName="text-success"
              />
              <RadialStat
                label="نسبة التسليم في الوقت"
                percent={monthly.on_time_rate ?? 0}
                colorClassName="text-amber-700 dark:text-amber-400"
              />
              <RadialStat
                label="معدل التأخير"
                percent={monthly.total_orders > 0 ? (monthly.delayed_orders / monthly.total_orders) * 100 : 0}
                colorClassName="text-warning"
              />
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="drivers" className="space-y-3 pt-4">
          {driverPerf.length > 0 && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">عدد الأوردرات لكل مندوب</CardTitle>
              </CardHeader>
              <CardContent>
                <BarList
                  items={driverPerf.map((d) => ({ label: d.full_name, value: d.total_orders }))}
                  colorClassName="bg-primary"
                />
              </CardContent>
            </Card>
          )}
          {driverPerf.length > 0 && (
            <Card>
              <CardHeader>
                <CardTitle className="text-base">نسبة التسليم في الموعد لكل مندوب</CardTitle>
              </CardHeader>
              <CardContent>
                <BarList
                  items={driverPerf.map((d) => ({ label: d.full_name, value: Math.round(d.on_time_rate ?? 0) }))}
                  colorClassName="bg-success"
                  max={100}
                  valueSuffix="%"
                />
              </CardContent>
            </Card>
          )}
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
                      <TableHead>نسبة التسليم في الموعد</TableHead>
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
                        <TableCell>{formatPercent(d.on_time_rate)}</TableCell>
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
            <CardContent>
              {topRegions.length === 0 ? (
                <EmptyState icon={BarChart3} title="لا يوجد بيانات مناطق بعد" />
              ) : (
                <BarList
                  items={topRegions.map((r) => ({ label: r.region_name, value: r.order_count }))}
                  colorClassName="bg-primary"
                />
              )}
            </CardContent>
          </Card>
        </TabsContent>

        <TabsContent value="delayed" className="pt-4">
          <Card>
            <CardContent className="p-0">
              {delayedOrders.length === 0 ? (
                <EmptyState icon={AlertTriangle} title="لا يوجد أوردرات متأخرة حاليًا" />
              ) : (
                <Table>
                  <TableHeader>
                    <TableRow>
                      <TableHead>رقم الأوردر</TableHead>
                      <TableHead>العميل</TableHead>
                      <TableHead>المنطقة</TableHead>
                      <TableHead>المندوب</TableHead>
                      <TableHead>الحالة</TableHead>
                      <TableHead>مدة التأخير</TableHead>
                    </TableRow>
                  </TableHeader>
                  <TableBody>
                    {delayedOrders.map((o) => (
                      <TableRow key={o.id}>
                        <TableCell className="font-medium" dir="ltr">
                          {o.order_number}
                        </TableCell>
                        <TableCell>{o.customer_name}</TableCell>
                        <TableCell>{o.region_name ?? "—"}</TableCell>
                        <TableCell>{o.driver_name ?? "—"}</TableCell>
                        <TableCell>
                          <OrderStatusBadge status={o.status} />
                        </TableCell>
                        <TableCell className="text-destructive">{formatHours(o.hours_open)}</TableCell>
                      </TableRow>
                    ))}
                  </TableBody>
                </Table>
              )}
            </CardContent>
          </Card>
        </TabsContent>
      </Tabs>
    </div>
  );
}
