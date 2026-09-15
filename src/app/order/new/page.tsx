import { redirect } from "next/navigation";
import { getCurrentProfile } from "@/lib/auth";

const ROLE_HOME: Record<string, string> = {
  owner: "/moderator/orders/new",
  moderator: "/moderator/orders/new",
  driver: "/driver",
  factory: "/factory",
};

/**
 * Order creation used to be open to anonymous customers here. Per a later
 * product decision, every order now goes through a signed-in team member
 * instead (see /moderator/orders/new, the real form — same <OrderForm>
 * component, just wired to createModeratorOrderAction instead of
 * createPublicOrderAction). This route is kept — rather than deleted
 * outright — as a redirect, so any bookmark, printed flyer, or old
 * Messenger reply pointing here still lands somewhere useful instead of a
 * 404: straight to sign-in, then straight into the order form.
 */
export default async function NewOrderPage() {
  const profile = await getCurrentProfile();
  if (!profile?.is_active) {
    redirect("/login?next=%2Fmoderator%2Forders%2Fnew");
  }
  redirect(ROLE_HOME[profile.role] ?? "/login");
}
