import { listRegions } from "@/lib/data/orders";
import { listFactories } from "@/lib/data/factories";
import { requireRole } from "@/lib/auth";
import { createModeratorOrderAction } from "@/lib/actions/orders";
import { OrderForm } from "@/components/orders/order-form";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { Alert, AlertDescription } from "@/components/ui/alert";
import { Info } from "lucide-react";

/**
 * Shared "أوردر جديد" page for both Owner and Moderator (this route's
 * layout allows both). As of migration 0027, both roles pick the factory
 * here — the one distribution decision still made at creation time — but
 * neither picks a driver directly, Owner included: the region alone is
 * enough for the system to fairly auto-suggest one, always left pending
 * the Owner's approval from <DistributionPanel> on the order's own page.
 */
export default async function ModeratorNewOrderPage() {
  await requireRole("owner", "moderator");

  const [regions, factories] = await Promise.all([listRegions(), listFactories()]);
  const activeFactories = factories.filter((f) => f.is_active);

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
              يجب اختيار المصنع عند تسجيل الأوردر — سيتم اقتراح مندوب تلقائيًا حسب المنطقة، وسيعتمده المدير قبل
              إرساله للمندوب
            </AlertDescription>
          </Alert>
          <OrderForm
            regions={regions}
            factories={activeFactories}
            requireFactory
            action={createModeratorOrderAction}
            submitLabel="تسجيل الأوردر"
          />
        </CardContent>
      </Card>
    </div>
  );
}
