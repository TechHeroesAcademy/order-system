import { requireRole } from "@/lib/auth";
import { listRegions } from "@/lib/data/orders";
import { listFactories } from "@/lib/data/factories";
import { OrderForm } from "@/components/orders/order-form";
import { createFieldOrderAction } from "@/lib/actions/orders";

export default async function DriverNewOrderPage() {
  await requireRole("driver");
  const [regions, factories] = await Promise.all([listRegions(), listFactories()]);

  return (
    <div className="mx-auto max-w-xl space-y-4">
      <h1 className="text-xl font-bold">أوردر جديد من الشارع</h1>

      <OrderForm
        regions={regions}
        factories={factories.filter((f) => f.is_active)}
        requireFactory
        showRegionHint={false}
        action={createFieldOrderAction}
        submitLabel="إنشاء وإسناده لي"
      />
    </div>
  );
}
