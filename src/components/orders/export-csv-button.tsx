"use client";

import { useTransition } from "react";
import { toast } from "sonner";
import { Loader2, Download } from "lucide-react";
import { Button } from "@/components/ui/button";
import { exportOrdersCsvAction } from "@/lib/actions/orders";

/**
 * "تحميل كل البيانات" — fetches every order as CSV text from
 * exportOrdersCsvAction (Owner-only) and turns it into a browser download
 * client-side. A Server Action can only return data, not a file response
 * with headers, so the Blob + object URL + synthetic <a click> is the
 * standard way to turn that data into an actual download without a
 * dedicated API route (this app has none — see AGENTS.md/CLAUDE.md for why
 * that's the established pattern here).
 */
export function ExportCsvButton() {
  const [pending, startTransition] = useTransition();

  function handleExport() {
    startTransition(async () => {
      const res = await exportOrdersCsvAction();
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      const blob = new Blob([res.data.csv], { type: "text/csv;charset=utf-8;" });
      const url = URL.createObjectURL(blob);
      const a = document.createElement("a");
      a.href = url;
      a.download = res.data.filename;
      document.body.appendChild(a);
      a.click();
      a.remove();
      URL.revokeObjectURL(url);
      toast.success("تم تحميل الملف");
    });
  }

  return (
    <Button size="sm" variant="outline" onClick={handleExport} disabled={pending}>
      {pending ? <Loader2 className="animate-spin" /> : <Download />}
      تحميل كل البيانات (CSV)
    </Button>
  );
}
