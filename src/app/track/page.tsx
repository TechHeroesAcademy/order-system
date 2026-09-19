// No "use client" here: nothing on this page is interactive. The one
// interactive piece is <TrackOrderForm>, which is its own client component,
// so marking the whole page client only shipped the card, the heading and
// the back link to the browser as JavaScript for no reason. This page is
// also the public-facing tracking entry point, so keeping it a server
// component is what lets its markup be part of the initial HTML.
import { Suspense } from "react";
import Link from "next/link";
import { ArrowRight } from "lucide-react";
import { Card, CardContent, CardDescription, CardHeader, CardTitle } from "@/components/ui/card";
import { TrackOrderForm } from "@/components/track/track-order-form";

export default function TrackPage() {
  return (
    <main className="mx-auto min-h-screen max-w-xl p-4 py-8">
      <Link href="/" className="mb-4 inline-flex items-center gap-1 text-sm text-muted-foreground hover:text-foreground">
        <ArrowRight className="size-4" />
        رجوع
      </Link>
      <Card className="overflow-hidden border-2">
        <CardHeader>
          <CardTitle>تتبع الأوردر</CardTitle>
          <CardDescription>أدخل رقم الأوردر ورقم الهاتف المسجل به</CardDescription>
        </CardHeader>
        <CardContent>
          <Suspense fallback={null}>
            <TrackOrderForm />
          </Suspense>
        </CardContent>
      </Card>
    </main>
  );
}
