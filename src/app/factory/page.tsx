import { listFactoryOrders, getFactoryOrderByNumber } from "@/lib/data/orders";
import { requireRole } from "@/lib/auth";
import { FactoryOrderCard } from "@/components/factory/factory-order-card";
import { EmptyState } from "@/components/shared/empty-state";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { Tabs, TabsContent, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { PackageSearch, Search } from "lucide-react";

export default async function FactoryPage({
  searchParams,
}: {
  searchParams: Promise<{ q?: string }>;
}) {
  await requireRole("factory");
  const { q } = await searchParams;
  const searchTerm = q?.trim();

  if (searchTerm) {
    const order = await getFactoryOrderByNumber(searchTerm);
    return (
      <div className="space-y-4">
        <SearchBox defaultValue={searchTerm} />
        {order ? (
          <FactoryOrderCard order={order} />
        ) : (
          <EmptyState
            icon={PackageSearch}
            title="لم يتم العثور على الأوردر"
            description="تأكد من رقم الأوردر، أو أنه لا يزال في مرحلة تخص المصنع."
          />
        )}
      </div>
    );
  }

  const orders = await listFactoryOrders();
  const collected = orders.filter((o) => o.status === "collected");
  const atFactory = orders.filter((o) => o.status === "at_factory");
  const ready = orders.filter((o) => o.status === "ready");

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-bold">أوردرات المصنع</h1>
      <SearchBox />

      <Tabs defaultValue="collected">
        <TabsList>
          <TabsTrigger value="collected">بانتظار الاستلام ({collected.length})</TabsTrigger>
          <TabsTrigger value="at_factory">داخل المصنع ({atFactory.length})</TabsTrigger>
          <TabsTrigger value="ready">جاهزة للتسليم ({ready.length})</TabsTrigger>
        </TabsList>

        <TabsContent value="collected" className="space-y-3 pt-3">
          <OrderGrid orders={collected} />
        </TabsContent>
        <TabsContent value="at_factory" className="space-y-3 pt-3">
          <OrderGrid orders={atFactory} />
        </TabsContent>
        <TabsContent value="ready" className="space-y-3 pt-3">
          <OrderGrid orders={ready} />
        </TabsContent>
      </Tabs>
    </div>
  );
}

function OrderGrid({ orders }: { orders: Awaited<ReturnType<typeof listFactoryOrders>> }) {
  if (orders.length === 0) {
    return <EmptyState icon={PackageSearch} title="لا يوجد أوردرات هنا حاليًا" />;
  }
  return (
    <div className="stagger-children grid gap-3 sm:grid-cols-2 lg:grid-cols-3">
      {orders.map((order) => (
        <FactoryOrderCard key={order.id} order={order} />
      ))}
    </div>
  );
}

function SearchBox({ defaultValue }: { defaultValue?: string }) {
  return (
    <form action="/factory" className="flex gap-2">
      <Input name="q" placeholder="ابحث برقم الأوردر" defaultValue={defaultValue} dir="ltr" />
      <Button type="submit" variant="outline" size="icon">
        <Search className="size-4" />
      </Button>
    </form>
  );
}
