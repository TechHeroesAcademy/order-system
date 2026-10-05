import Link from "next/link";
import { History, AlertTriangle, ArrowLeft } from "lucide-react";
import { buildCustomerSequenceNote } from "@/lib/domain/customer-history";
import type { OrderCustomerContext } from "@/types/database";

export function CustomerHistoryNote({
  context,
  orderBasePath,
}: {
  context: OrderCustomerContext | null;
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
