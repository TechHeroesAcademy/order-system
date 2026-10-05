"use client";

import { useTransition } from "react";
import { useRouter } from "next/navigation";
import { LogOut } from "lucide-react";
import { signOutAction } from "@/lib/actions/staff-auth";
import { DropdownMenuItem } from "@/components/ui/dropdown-menu";

export function SignOutButton() {
  const router = useRouter();
  const [pending, startTransition] = useTransition();

  function handleSignOut() {
    startTransition(async () => {
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
