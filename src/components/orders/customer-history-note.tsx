import Link from "next/link";
import { History, AlertTriangle, ArrowLeft } from "lucide-react";
import { buildCustomerSequenceNote } from "@/lib/domain/customer-history";
import type { OrderCustomerContext } from "@/types/database";

/**
 * "This is order 3 of 4 for this customer", on the order's own page.
 *
 * The counterpart to the confirmation shown while an order is being created
 * (RepeatCustomerDialog): that one asks the person creating it, this one
 * tells whoever opens it afterwards. It matters most on a driver's field
 * order, which reaches a driver with nobody approving it — reading the order
 * later is the only check there is.
 *
 * Renders nothing for a customer with one order, which is most of them. A
 * line on every order would be noise, and noise is exactly what would stop
 * the repeat case being noticed.
 *
 * A plain strip above the customer details rather than an Alert: it is a
 * fact about the order in the ordinary case, and only becomes a warning
 * when the customer has something else still open — so it changes colour
 * for that case instead of shouting on every repeat customer.
 */
export function CustomerHistoryNote({
  context,
  orderBasePath,
}: {
  context: OrderCustomerContext | null;
  /** Where an order's page lives for this viewer — "/owner/orders" or "/moderator/orders". */
  orderBasePath: string;
}) {
  const note = buildCustomerSequenceNote(context);
  if (!note) return null;

  return (
    <div
      className={
        "mb-4 rounded-lg border p-3 " +
        (note.openWarning ? "border-warning/40 bg-warning/10" : "border-border bg-muted/40")
      }
    >
      <p className="flex items-center gap-2 text-sm font-medium">
        {note.openWarning ? (
          <AlertTriangle className="size-4 shrink-0 text-warning" />
        ) : (
          <History className="size-4 shrink-0 text-muted-foreground" />
        )}
        {note.headline}
      </p>

      {note.openWarning && <p className="mt-1 text-sm">{note.openWarning}</p>}

      {note.previous && (
        <Link
          href={`${orderBasePath}/${note.previous.id}`}
          className="mt-1.5 inline-flex items-center gap-1 text-xs text-muted-foreground hover:text-foreground hover:underline"
        >
          <ArrowLeft className="size-3" />
          {note.previous.label}
        </Link>
      )}
    </div>
  );
}
