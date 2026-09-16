import { listRegions } from "@/lib/data/orders";
import { listStaff } from "@/lib/data/staff";
import { createModeratorOrderAction } from "@/lib/actions/orders";
import { OrderForm } from "@/components/orders/order-form";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Info } from "lucide-react";

export default async function ModeratorNewOrderPage() {
  const [regions, factories, drivers] = await Promise.all([
    listRegions(),
    listStaff("factory"),
    listStaff("driver"),
  ]);
  const activeFactories = factories.filter((f) => f.is_active);
  const activeDrivers = drivers.filter((d) => d.is_active);

  return (
    <div className="mx-auto max-w-2xl space-y-4">
      <Card>
        <CardHeader>
          <CardTitle className="text-lg">تسجيل أوردر جديد (Messenger / هاتف)</CardTitle>
        </CardHeader>
        <CardContent className="space-y-4">
          <Alert>
            <Info className="size-4" />
            <AlertDescription>يجب اختيار المندوب والمصنع عند تسجيل الأوردر</AlertDescription>
          </Alert>
          <OrderForm
            regions={regions}
            factories={activeFactories}
            drivers={activeDrivers}
            requireDriverAndFactory
            action={createModeratorOrderAction}
            submitLabel="تسجيل الأوردر"
          />
        </CardContent>
      </Card>
    </div>
  );
}
