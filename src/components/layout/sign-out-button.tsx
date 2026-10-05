"use client";

import { useTransition } from "react";
import { useRouter } from "next/navigation";
import { LogOut } from "lucide-react";
import { signOutAction } from "@/lib/actions/staff-auth";
import { deletePushSubscriptionAction } from "@/lib/actions/push";
import { getExistingSubscription } from "@/lib/push/client";
import { DropdownMenuItem } from "@/components/ui/dropdown-menu";

export function SignOutButton() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();

  function handleSignOut() {
    startTransition(async () => {
      try {
        const subscription = await getExistingSubscription();
        if (subscription) {
          await deletePushSubscriptionAction(subscription.endpoint);
        }
      } catch {
      }

      try {
        for (let i = sessionStorage.length - 1; i >= 0; i--) {
          const key = sessionStorage.key(i);
          if (key?.startsWith("push-bound:")) sessionStorage.removeItem(key);
        }
      } catch {
      }

      await signOutAction();
      router.replace("/login");
      router.refresh();
    });
  }

  return (
    <DropdownMenuItem onClick={handleSignOut} disabled={pending} variant="destructive">
      <LogOut />
      تسجيل الخروج
    </DropdownMenuItem>
  );
}
