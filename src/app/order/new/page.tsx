import { redirect } from "next/navigation";
import { getCurrentProfile } from "@/lib/auth";

const ROLE_HOME: Record<string, string> = {
  owner: "/moderator/orders/new",
  moderator: "/moderator/orders/new",
  driver: "/driver",
  factory: "/login",
};

export default async function NewOrderPage() {
  const profile = await getCurrentProfile();
  if (!profile?.is_active) {
    redirect("/login?next=%2Fmoderator%2Forders%2Fnew");
  }
  redirect(ROLE_HOME[profile.role] ?? "/login");
}
