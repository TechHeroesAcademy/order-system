import { requireRole } from "@/lib/auth";
import { listRegions } from "@/lib/data/orders";
import { listFactories } from "@/lib/data/factories";
import { OrderForm } from "@/components/orders/order-form";
import { createFieldOrderAction } from "@/lib/actions/orders";
import { Alert, AlertDescription, AlertTitle } from "@/components/ui/alert";
import { Zap } from "lucide-react";

/**
 * The driver's own order form — for a job negotiated on the doorstep while
 * they were out delivering something else.
 *
 * Reuses OrderForm rather than growing a second one: the fields are the
 * same, only the action behind it differs. The form has no driver picker at
 * all (since migration 0027), which is exactly right here — the driver is
 * taken from the session by the RPC and is not a field anyone can set.
 */
export default async function DriverNewOrderPage() {
  await requireRole("driver");
  const [regions, factories] = await Promise.all([listRegions(), listFactories()]);

  return (
    <div className="mx-auto max-w-xl space-y-4">
      <h1 className="text-xl font-bold">أوردر جديد من الشارع</h1>

      {/* Said plainly, because it is the one thing that makes this form
          different from every other way an order is created — and the
          driver is accountable for it. */}
      <Alert>
        <Zap className="size-4" />
        <AlertTitle>هذا الأوردر سيُسند إليك فورًا</AlertTitle>
        <AlertDescription>
          لا يحتاج اعتماد من المدير، وسيظهر في أوردراتك مباشرة. سيصل إشعار للمدير بأنك أنشأته.
        </AlertDescription>
      </Alert>

      <OrderForm
        regions={regions}
        factories={factories.filter((f) => f.is_active)}
        requireFactory
        action={createFieldOrderAction}
        submitLabel="إنشاء وإسناده لي"
      />
    </div>
  );
}
