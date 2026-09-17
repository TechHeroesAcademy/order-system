import { listRegions } from "@/lib/data/orders";
import { listStaff } from "@/lib/data/staff";
import { requireRole } from "@/lib/auth";
import { createModeratorOrderAction } from "@/lib/actions/orders";
import { OrderForm } from "@/components/orders/order-form";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Info } from "lucide-react";

/**
 * Shared "أوردر جديد" page for both Owner and Moderator (this route's
 * layout allows both) — but as of migration 0024, only the Owner ("the
 * manager") picks the driver and factory directly here. A Moderator's copy
 * of this form drops both fields entirely: the region alone is enough for
 * the system to fairly auto-suggest a driver (pending the Owner's approval
 * from the orders list/detail page), and the factory is left for the Owner
 * to assign afterward.
 */
export default async function ModeratorNewOrderPage() {
  const profile = await requireRole("owner", "moderator");
  const isOwner = profile.role === "owner";

  const [regions, factories, drivers] = await Promise.all([
    listRegions(),
    isOwner ? listStaff("factory") : Promise.resolve([]),
    isOwner ? listStaff("driver") : Promise.resolve([]),
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
            <AlertDescription>
              {isOwner
                ? "يجب اختيار المندوب والمصنع عند تسجيل الأوردر"
                : "سيتم اقتراح مندوب تلقائيًا حسب المنطقة، وسيعتمده المدير قبل إرساله — تحديد المندوب والمصنع من صلاحية المدير"}
            </AlertDescription>
          </Alert>
          <OrderForm
            regions={regions}
            factories={activeFactories}
            drivers={activeDrivers}
            requireDriverAndFactory={isOwner}
            showDistributionFields={isOwner}
            action={createModeratorOrderAction}
            submitLabel="تسجيل الأوردر"
          />
        </CardContent>
      </Card>
    </div>
  );
}
