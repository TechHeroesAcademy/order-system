import { listRegions } from "@/lib/data/orders";
import { createModeratorOrderAction } from "@/lib/actions/orders";
import { OrderForm } from "@/components/orders/order-form";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

export default async function ModeratorNewOrderPage() {
  const regions = await listRegions();

  return (
    <div className="mx-auto max-w-2xl space-y-4">
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">تسجيل أوردر جديد (Messenger / هاتف)</CardTitle>
        </CardHeader>
        <CardContent>
          <OrderForm regions={regions} action={createModeratorOrderAction} submitLabel="تسجيل الأوردر" />
        </CardContent>
      </Card>
    </div>
  );
}
