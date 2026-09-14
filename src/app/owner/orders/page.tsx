import Link from "next/link";
import { listOrders, listRegions } from "@/lib/data/orders";
import { listStaff } from "@/lib/data/staff";
import { OrdersFilterBar } from "@/components/orders/orders-filter-bar";
import { OrdersTable } from "@/components/orders/orders-table";
import { Card, CardContent } from "@/components/ui/card";
import { Button } from "@/components/ui/button";
import type { OrderStatus } from "@/types/database";

export default async function OwnerOrdersPage({
  searchParams,
}: {
  searchParams: Promise<{ [key: string]: string | string[] | undefined }>;
}) {
  const sp = await searchParams;
  const status = (typeof sp.status === "string" ? sp.status : "all") as OrderStatus | "all";
  const regionId = typeof sp.region === "string" ? sp.region : "all";
  const driverId = typeof sp.driver === "string" ? sp.driver : "all";
  const search = typeof sp.q === "string" ? sp.q : "";
  const dateFrom = typeof sp.from === "string" && sp.from ? sp.from : undefined;
  const dateTo = typeof sp.to === "string" && sp.to ? sp.to : undefined;
  const minPieces = typeof sp.minPieces === "string" && sp.minPieces ? Number(sp.minPieces) : undefined;
  const maxPieces = typeof sp.maxPieces === "string" && sp.maxPieces ? Number(sp.maxPieces) : undefined;
  const page = typeof sp.page === "string" ? Number(sp.page) || 1 : 1;

  const [{ orders, total }, regions, drivers] = await Promise.all([
    listOrders({ status, regionId, driverId, search, dateFrom, dateTo, minPieces, maxPieces, page, pageSize: 25 }),
    listRegions(),
    listStaff("driver"),
  ]);

  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <h1 className="text-xl font-bold">الأوردرات</h1>
        <Button asChild size="sm">
          <Link href="/moderator/orders/new">أوردر جديد</Link>
        </Button>
      </div>

      <OrdersFilterBar regions={regions} drivers={drivers} basePath="/owner/orders" />

      <Card>
        <CardContent className="p-0">
          <OrdersTable orders={orders} regions={regions} basePath="/owner/orders" />
        </CardContent>
      </Card>

      <Pagination total={total} page={page} pageSize={25} basePath="/owner/orders" searchParams={sp} />
    </div>
  );
}

function Pagination({
  total,
  page,
  pageSize,
  basePath,
  searchParams,
}: {
  total: number;
  page: number;
  pageSize: number;
  basePath: string;
  searchParams: Record<string, string | string[] | undefined>;
}) {
  const totalPages = Math.max(1, Math.ceil(total / pageSize));
  if (totalPages <= 1) return null;

  function pageHref(p: number) {
    const params = new URLSearchParams();
    for (const [k, v] of Object.entries(searchParams)) {
      if (k === "page") continue;
      if (typeof v === "string") params.set(k, v);
    }
    params.set("page", String(p));
    return `${basePath}?${params.toString()}`;
  }

  return (
    <div className="flex items-center justify-between text-sm text-muted-foreground">
      <span>
        صفحة {page} من {totalPages} · {total} أوردر
      </span>
      <div className="flex gap-2">
        {page > 1 && (
          <Button asChild size="sm" variant="outline">
            <Link href={pageHref(page - 1)}>السابق</Link>
          </Button>
        )}
        {page < totalPages && (
          <Button asChild size="sm" variant="outline">
            <Link href={pageHref(page + 1)}>التالي</Link>
          </Button>
        )}
      </div>
    </div>
  );
}
