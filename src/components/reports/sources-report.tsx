import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { Table, TableBody, TableCell, TableHead, TableHeader, TableRow } from "@/components/ui/table";
import { StatCard } from "@/components/shared/stat-card";
import { BarList } from "@/components/reports/bar-list";
import { EmptyState } from "@/components/shared/empty-state";
import { orderSourceLabel } from "@/lib/domain/order-source";
import { PackageSearch, Zap } from "lucide-react";
import type { OrderSourceRow, OrderCreatorRow } from "@/types/database";

export function SourcesReport({
  bySource,
  byCreator,
}: {
  bySource: OrderSourceRow[];
  byCreator: OrderCreatorRow[];
}) {
  const total = bySource.reduce((sum, r) => sum + r.order_count, 0);
  const field = bySource.find((r) => r.source === "driver_field");
  const fieldCount = field?.order_count ?? 0;
  const fieldDelivered = field?.delivered_count ?? 0;
  const fieldShare = total > 0 ? Math.round((fieldCount / total) * 100) : 0;
  const fieldCompletion = fieldCount > 0 ? Math.round((fieldDelivered / fieldCount) * 100) : 0;

  if (total === 0) {
    return <EmptyState icon={PackageSearch} title="لا توجد أوردرات هذا الشهر" />;
  }

  return (
    <div className="space-y-3">
      <div className="grid gap-3 sm:grid-cols-2 lg:grid-cols-4">
        <StatCard label="إجمالي أوردرات الشهر" value={total} />
        <StatCard label="أوردرات ميدانية" value={fieldCount} />
        <StatCard label="نسبة الميدانية" value={`${fieldShare}%`} />
        <StatCard label="تم تسليمها من الميدانية" value={`${fieldCompletion}%`} />
      </div>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">الأوردرات حسب المصدر</CardTitle>
        </CardHeader>
        <CardContent>
          <BarList
            items={bySource.map((r) => ({
              label: orderSourceLabel(r.source),
              value: r.order_count,
            }))}
          />
        </CardContent>
      </Card>

      <Card>
        <CardHeader>
          <CardTitle className="text-base">من أنشأ الأوردرات</CardTitle>
        </CardHeader>
        <CardContent className="p-0">
          <Table>
            <TableHeader>
              <TableRow>
                <TableHead>الاسم</TableHead>
                <TableHead>الدور</TableHead>
                <TableHead>أنشأ</TableHead>
                <TableHead>منها ميدانية</TableHead>
                <TableHead>تم تسليمها</TableHead>
              </TableRow>
            </TableHeader>
            <TableBody>
              {byCreator.map((row) => (
                <TableRow key={`${row.creator_name}-${row.creator_role}`}>
                  <TableCell className="font-medium">{row.creator_name}</TableCell>
                  <TableCell className="text-muted-foreground">{ROLE_LABELS[row.creator_role] ?? row.creator_role}</TableCell>
                  <TableCell className="tabular-nums">{row.order_count}</TableCell>
                  <TableCell>
                    {row.field_order_count > 0 ? (
                      <span className="flex items-center gap-1.5">
                        <Badge variant="warning">
                          <Zap className="size-3" />
                          {row.field_order_count}
                        </Badge>
                      </span>
                    ) : (
                      <span className="text-muted-foreground">—</span>
                    )}
                  </TableCell>
                  <TableCell className="tabular-nums text-muted-foreground">{row.delivered_count}</TableCell>
                </TableRow>
              ))}
            </TableBody>
          </Table>
        </CardContent>
      </Card>
    </div>
  );
}

const ROLE_LABELS: Record<string, string> = {
  owner: "مدير",
  moderator: "موديريتور",
  driver: "مندوب",
  factory: "المصنع",
};
