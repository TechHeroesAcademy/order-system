import { redirect } from "next/navigation";

/**
 * The distribution board moved to /owner/distribution. This exists only so a
 * bookmark, a browser autocomplete, or a link someone pasted in a chat months
 * ago still lands somewhere sensible instead of a 404.
 *
 * redirect() throws before anything renders, so this never draws the
 * moderator layout — which matters, since a Manager being rendered by that
 * layout is the exact bug the move fixed. A Moderator following the old link
 * is bounced by the proxy from /owner/* to their own home, so this leaks no
 * access either.
 */
export default function MovedDistributionPage() {
  redirect("/owner/distribution");
}
