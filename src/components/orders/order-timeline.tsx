import { CheckCircle2, XCircle } from "lucide-react";
import { eventTypeLabel } from "@/lib/domain/order-status";
import { formatDateTime } from "@/lib/domain/format";
import type { OrderHistoryEntry } from "@/types/database";

const NEGATIVE_EVENTS = new Set(["delivery_code_mismatch", "refused", "cancelled", "distribution_cleared"]);

export function OrderTimeline({ entries }: { entries: OrderHistoryEntry[] }) {
  if (entries.length === 0) {
    return <p className="text-sm text-muted-foreground">لا يوجد سجل حركة بعد.</p>;
  }

  return (
    <ol className="space-y-4">
      {entries.map((entry, idx) => {
        const isNegative = NEGATIVE_EVENTS.has(entry.event_type);
        // Every row here already happened — it's a log of completed steps,
        // not a plan of upcoming ones — so every non-negative entry gets the
        // "done" checkmark, not just the most recent one ("the steps
        // happened should be marked done with the right sign").
        const Icon = isNegative ? XCircle : CheckCircle2;
        return (
          <li
            key={entry.id}
            className="flex gap-3 animate-fade-in-up"
            style={{ animationDelay: `${Math.min(idx, 10) * 60}ms` }}
          >
            <div className="flex flex-col items-center">
              <Icon
                className={
                  (isNegative ? "size-5 text-destructive" : "size-5 text-success") + " animate-pop-in"
                }
                style={{ animationDelay: `${Math.min(idx, 10) * 60 + 120}ms` }}
              />
              {idx < entries.length - 1 && (
                <div
                  className="w-px flex-1 origin-top bg-border animate-draw-line"
                  style={{ animationDelay: `${Math.min(idx, 10) * 60 + 100}ms` }}
                />
              )}
            </div>
            <div className="pb-4">
              <p className="text-sm font-medium">{eventTypeLabel(entry.event_type)}</p>
              {entry.note && <p className="text-sm text-muted-foreground">{entry.note}</p>}
              <p className="text-xs text-muted-foreground">
                {formatDateTime(entry.created_at)}
                {entry.actor_role ? ` · ${roleLabel(entry.actor_role)}` : ""}
              </p>
            </div>
          </li>
        );
      })}
    </ol>
  );
}

function roleLabel(role: string) {
  const labels: Record<string, string> = {
    owner: "مدير",
    moderator: "موديريتور",
    driver: "مندوب",
    factory: "مصنع",
  };
  return labels[role] ?? role;
}
