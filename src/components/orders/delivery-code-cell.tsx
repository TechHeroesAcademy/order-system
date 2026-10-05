"use client";

import { useState } from "react";
import { Eye, EyeOff } from "lucide-react";

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
