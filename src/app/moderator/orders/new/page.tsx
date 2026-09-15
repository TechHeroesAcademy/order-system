import { listRegions } from "@/lib/data/orders";
import { listStaff } from "@/lib/data/staff";
import { createModeratorOrderAction } from "@/lib/actions/orders";
import { OrderForm } from "@/components/orders/order-form";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

export default async function ModeratorNewOrderPage() {
  const [regions, factories] = await Promise.all([listRegions(), listStaff("factory")]);
  const activeFactories = factories.filter((f) => f.is_active);

  return (
    <div className="mx-auto max-w-2xl space-y-4">
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">تسجيل أوردر جديد (Messenger / هاتف)</CardTitle>
        </CardHeader>
        <CardContent>
          <OrderForm
            regions={regions}
            factories={activeFactories}
            action={createModeratorOrderAction}
            submitLabel="تسجيل الأوردر"
          />
        </CardContent>
      </Card>
    </div>
  );
}
