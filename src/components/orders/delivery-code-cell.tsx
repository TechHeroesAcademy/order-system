"use client";

import { useState } from "react";
import { Eye, EyeOff } from "lucide-react";

/**
 * Shows an order's delivery code right in the orders list, masked by
 * default with a click-to-reveal toggle — the code is already fetched in
 * one batch RPC for the whole page (see getOrderDeliveryCodesMap), so this
 * is purely a local display toggle, no network round trip. Masked-by-default
 * keeps the same "not just sitting on screen" spirit as the order-detail
 * reveal (<DeliveryCodeReveal>) while still satisfying "the code should
 * appear in the orders list for each order" — it's right there, one click away.
 */
export function DeliveryCodeCell({ code }: { code: string | null }) {
  const [revealed, setRevealed] = useState(false);

  if (!code) {
    return <span className="text-xs text-muted-foreground">—</span>;
  }

  return (
    <button
      type="button"
      onClick={() => setRevealed((v) => !v)}
      className="inline-flex items-center gap-1.5 rounded-md border px-2 py-1 font-mono text-xs tabular-nums transition-colors hover:bg-accent"
      title={revealed ? "إخفاء الكود" : "إظهار الكود"}
    >
      <span className="tracking-widest">{revealed ? code : "••••"}</span>
      {revealed ? <EyeOff className="size-3 text-muted-foreground" /> : <Eye className="size-3 text-muted-foreground" />}
    </button>
  );
}
