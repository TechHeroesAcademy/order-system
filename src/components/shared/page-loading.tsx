import { Skeleton } from "@/components/ui/skeleton";

/**
 * Generic route-level loading fallback (see each role's app/loading.tsx).
 * Next.js shows this the instant a navigation starts, in place of the previous
 * page's content is frozen — since none of these routes had a loading.tsx
 * before, clicking a nav tab or a link left the UI showing zero feedback
 * until every server-side query on the destination page finished (several
 * Promise.all'd Supabase calls on most pages here), which is a big part of
 * why moving between tabs felt slow/unresponsive even when the underlying
 * queries were reasonably fast. This never needs to match the destination
 * page's exact shape — it just has to appear immediately.
 */
export function PageLoading() {
  return (
    <div className="space-y-4">
      <div className="flex items-center justify-between">
        <Skeleton className="h-7 w-40" />
        <Skeleton className="h-9 w-28" />
      </div>
      <Skeleton className="h-10 w-full max-w-md" />
      <div className="space-y-2">
        <Skeleton className="h-12 w-full" />
        <Skeleton className="h-12 w-full" />
        <Skeleton className="h-12 w-full" />
        <Skeleton className="h-12 w-full" />
        <Skeleton className="h-12 w-full" />
      </div>
    </div>
  );
}
