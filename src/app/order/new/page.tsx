import Link from "next/link";
import { ArrowRight } from "lucide-react";
import { OrderForm } from "@/components/orders/order-form";
import { listRegions } from "@/lib/data/orders";
import { createPublicOrderAction } from "@/lib/actions/orders";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";

export default async function NewOrderPage() {
  const regions = await listRegions();

  return (
    <main className="mx-auto min-h-screen max-w-xl p-4 py-8">
      <Link href="/" className="mb-4 inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground">
        <ArrowRight className="size-4" />
        رجوع
      </Link>
      <Card>
        <CardHeader>
          <CardTitle>إنشاء أوردر جديد</CardTitle>
          <CardDescription>أدخل بياناتك وسيتم التواصل معك لتنفيذ الأوردر ومتابعته</CardDescription>
        </CardHeader>
        <CardContent>
          <OrderForm regions={regions} action={createPublicOrderAction} />
        </CardContent>
      </Card>
    </main>
  );
}
