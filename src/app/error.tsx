"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { AlertTriangle, RotateCcw, Home, Copy, Check } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

export default function ErrorBoundary({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    console.error(error);
  }, [error]);

  async function copyDigest() {
    if (!error.digest) return;
    try {
      await navigator.clipboard.writeText(error.digest);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
    }
  }

  return (
    <div className="flex min-h-[70vh] items-center justify-center p-4">
      <Card className="w-full max-w-md">
        <CardHeader className="items-center text-center">
          <div className="mb-2 flex size-12 items-center justify-center rounded-full bg-destructive/10">
            <AlertTriangle className="size-6 text-destructive" />
          </div>
          <CardTitle className="text-lg">حدث خطأ غير متوقع</CardTitle>
        </CardHeader>
        <CardContent className="flex flex-col items-center gap-4 text-center">
          <p className="text-sm text-muted-foreground">
            صفحة لم تُحمَّل بشكل صحيح. جرّب مرة أخرى، ولو استمرت المشكلة أرسل الكود
            اللي تحت لفريق الدعم الفني.
          </p>

          {error.digest && (
            <button
              type="button"
              onClick={copyDigest}
              className="flex items-center gap-2 rounded-md border bg-muted px-3 py-2 font-mono text-xs text-muted-foreground transition-colors hover:bg-accent"
            >
              {copied ? (
                <Check className="size-3.5 text-success" />
              ) : (
                <Copy className="size-3.5" />
              )}
              {error.digest}
            </button>
          )}

          <div className="flex w-full gap-2">
            <Button onClick={reset} className="flex-1" variant="default">
              <RotateCcw />
              حاول مرة أخرى
            </Button>
            <Button asChild variant="outline" className="flex-1">
              <Link href="/">
                <Home />
                الرئيسية
              </Link>
            </Button>
          </div>
        </CardContent>
      </Card>
    </div>
  );
}
