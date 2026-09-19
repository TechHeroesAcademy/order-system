"use client";

import { useCallback, useEffect, useState, useTransition } from "react";
import { toast } from "sonner";
import { Bell, BellOff, Loader2, Share, SquarePlus } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent } from "@/components/ui/card";
import { savePushSubscriptionAction, deletePushSubscriptionAction } from "@/lib/actions/push";
import {
  getPushCapability,
  subscribeToPush,
  unsubscribeFromPush,
  type PushCapability,
} from "@/lib/push/client";

/**
 * Turns phone notifications on, and explains honestly when it can't.
 *
 * Renders nothing at all until the capability check has run on the client.
 * That is deliberate: every branch below depends on browser APIs that don't
 * exist during server rendering, so a server-rendered guess would flash the
 * wrong message — most visibly telling an iPhone user to install the app
 * when they already have.
 */
export function PushSetupCard({ vapidPublicKey }: { vapidPublicKey: string }) {
  const [capability, setCapability] = useState<PushCapability | null>(null);
  const [pending, startTransition] = useTransition();
  const [working, setWorking] = useState(false);

  const refresh = useCallback(() => {
    void getPushCapability().then(setCapability);
  }, []);

  useEffect(() => {
    refresh();
  }, [refresh]);

  async function enable() {
    setWorking(true);
    try {
      const subscription = await subscribeToPush(vapidPublicKey);
      const result = await savePushSubscriptionAction(subscription);
      if (!result.ok) {
        toast.error(result.error);
        // The browser subscription exists but the server doesn't know about
        // it, which would look enabled and never deliver anything. Roll it
        // back so the next attempt starts clean.
        await unsubscribeFromPush();
        return;
      }
      toast.success("تم تفعيل الإشعارات على هذا الجهاز");
      refresh();
    } catch (error) {
      toast.error(error instanceof Error ? error.message : "تعذر تفعيل الإشعارات");
      refresh();
    } finally {
      setWorking(false);
    }
  }

  function disable() {
    setWorking(true);
    void (async () => {
      try {
        const endpoint = await unsubscribeFromPush();
        if (endpoint) {
          startTransition(() => {
            void deletePushSubscriptionAction(endpoint);
          });
        }
        toast.success("تم إيقاف الإشعارات على هذا الجهاز");
        refresh();
      } finally {
        setWorking(false);
      }
    })();
  }

  if (capability === null) return null;

  // Nothing to offer and nothing useful to say — an old browser or a
  // private window. Silence beats an error the person can do nothing about.
  if (capability === "unsupported") return null;

  const busy = working || pending;

  if (capability === "subscribed") {
    return (
      <Card className="border-success/40 bg-success/5">
        <CardContent className="flex items-center justify-between gap-3 py-3">
          <div className="flex items-center gap-2 text-sm">
            <Bell className="size-4 shrink-0 text-success" />
            <span>الإشعارات مفعّلة على هذا الجهاز</span>
          </div>
          <Button variant="ghost" size="sm" onClick={disable} disabled={busy}>
            {busy ? <Loader2 className="size-4 animate-spin" /> : <BellOff className="size-4" />}
            إيقاف
          </Button>
        </CardContent>
      </Card>
    );
  }

  if (capability === "denied") {
    return (
      <Card className="border-warning/40 bg-warning/5">
        <CardContent className="space-y-1 py-3 text-sm">
          <p className="flex items-center gap-2 font-medium">
            <BellOff className="size-4 shrink-0" />
            الإشعارات محظورة في هذا المتصفح
          </p>
          {/* The permission can only be restored from browser settings — the
              site is not allowed to ask again once refused, so offering a
              button here would be a button that does nothing. */}
          <p className="text-muted-foreground">
            لإعادة تفعيلها، افتح إعدادات الموقع في المتصفح واسمح بالإشعارات، ثم أعد تحميل الصفحة.
          </p>
        </CardContent>
      </Card>
    );
  }

  if (capability === "ios-needs-install") {
    return (
      <Card className="border-primary/40 bg-primary/5">
        <CardContent className="space-y-2 py-3 text-sm">
          <p className="flex items-center gap-2 font-medium">
            <Bell className="size-4 shrink-0" />
            لتفعيل الإشعارات على الآيفون، أضف التطبيق للشاشة الرئيسية أولًا
          </p>
          {/* This is an Apple platform rule, not something the app can work
              around: iOS gives web apps notifications only after they are
              installed. Saying so plainly is better than a button that
              silently fails. */}
          <ol className="space-y-1 text-muted-foreground">
            <li className="flex items-center gap-2">
              <span className="font-medium text-foreground">١.</span>
              اضغط زر المشاركة
              <Share className="size-4" />
              في شريط سفاري
            </li>
            <li className="flex items-center gap-2">
              <span className="font-medium text-foreground">٢.</span>
              اختر «إضافة إلى الشاشة الرئيسية»
              <SquarePlus className="size-4" />
            </li>
            <li>
              <span className="font-medium text-foreground">٣.</span> افتح التطبيق من الأيقونة
              الجديدة، وستجد زر تفعيل الإشعارات هنا
            </li>
          </ol>
          <p className="text-xs text-muted-foreground">
            يحتاج الآيفون نظام iOS 16.4 أو أحدث. على الأندرويد تعمل الإشعارات من المتصفح مباشرة بدون
            تثبيت.
          </p>
        </CardContent>
      </Card>
    );
  }

  return (
    <Card className="border-primary/40 bg-primary/5">
      <CardContent className="flex flex-wrap items-center justify-between gap-3 py-3">
        <div className="flex items-center gap-2 text-sm">
          <Bell className="size-4 shrink-0" />
          <span>فعّل الإشعارات ليصلك تنبيه على هاتفك فور وصول أوردر أو رسالة</span>
        </div>
        <Button size="sm" onClick={enable} disabled={busy}>
          {busy ? <Loader2 className="size-4 animate-spin" /> : <Bell className="size-4" />}
          تفعيل الإشعارات
        </Button>
      </CardContent>
    </Card>
  );
}
