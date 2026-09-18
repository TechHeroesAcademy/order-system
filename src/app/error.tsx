"use client";

import { useEffect, useState } from "react";
import Link from "next/link";
import { AlertTriangle, RotateCcw, Home, Copy, Check } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";

/**
 * Root error boundary — every page under this app (factory/owner/driver/
 * moderator order pages, reports, etc.) previously had NO error.tsx
 * anywhere, so any uncaught Server Component throw fell through to Next's
 * bare built-in error screen: a generic "Application error" with no digest
 * shown and no way forward except reloading. That's the "error page" users
 * have repeatedly reported over several rounds (factory order-detail
 * crashes, now also the reports page) — indistinguishable from each other
 * on screen even when their actual causes differ, which made them look like
 * "the same error" and made them impossible to diagnose without direct
 * access to the live Vercel/Supabase project (which this workspace has
 * never had).
 *
 * This doesn't fix any specific underlying bug — it can't, since production
 * strips the real thrown message from what ships to the browser by design
 * (Next.js only exposes `error.digest`, a short id that correlates to the
 * full un-minified message in the server's own Runtime Logs). What it adds:
 * a friendly on-brand screen instead of a bare crash, a "try again" that
 * re-renders the segment via `reset()` instead of forcing a full reload,
 * and the digest surfaced + copyable right on screen — so the next time
 * this happens, whoever hits it can hand over one short code instead of a
 * screenshot of a message that was never informative to begin with.
 */
export default function ErrorBoundary({
  error,
  reset,
}: {
  error: Error & { digest?: string };
  reset: () => void;
}) {
  const [copied, setCopied] = useState(false);

  useEffect(() => {
    // Still shows up in Vercel's Runtime Logs on its own via the platform's
    // own capture, but logging it here too costs nothing and keeps the
    // browser console non-empty for anyone who does have devtools open.
    console.error(error);
  }, [error]);

  async function copyDigest() {
    if (!error.digest) return;
    try {
      await navigator.clipboard.writeText(error.digest);
      setCopied(true);
      setTimeout(() => setCopied(false), 2000);
    } catch {
      // Clipboard access can fail (permissions, insecure context) — the
      // digest is still selectable/readable on screen either way.
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
