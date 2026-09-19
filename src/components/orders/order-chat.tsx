"use client";

import { useCallback, useEffect, useRef, useState, useTransition } from "react";
import { toast } from "sonner";
import { Loader2, MessageCircle, Send } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Textarea } from "@/components/ui/textarea";
import { Card, CardContent, CardHeader, CardTitle } from "@/components/ui/card";
import { listOrderMessagesAction, sendOrderMessageAction } from "@/lib/actions/orders";
import { formatRelative } from "@/lib/domain/format";
import type { OrderChatChannel, OrderMessage } from "@/types/database";

const ROLE_LABELS_AR: Record<string, string> = {
  owner: "مدير",
  moderator: "موديريتور",
  driver: "مندوب",
  factory: "مصنع",
};

const CHANNEL_TITLES_AR: Record<OrderChatChannel, string> = {
  driver: "دردشة المندوب",
  factory: "دردشة المصنع",
};

/**
 * Poll cadence, in ms. The chat has no realtime channel (deliberately — see
 * the note below), so it asks the server on a timer. It starts fast and backs
 * off while nothing is happening, then snaps back to fast the moment anything
 * does: a message arrives, you send one, or the panel scrolls into view.
 *
 * This matters because it runs on a page a driver may leave open for a whole
 * shift. At a flat 4s that was ~900 requests an hour per open order page —
 * each one a server round-trip that re-verifies the session and re-reads the
 * thread — whether or not anyone was looking at it. With backoff, an idle
 * conversation costs about a fifteenth of that, while an active one is
 * exactly as responsive as before.
 */
const POLL_LADDER_MS = [4000, 4000, 4000, 10000, 10000, 30000] as const;
const POLL_IDLE_MS = 60000;

/**
 * The per-order conversation between the assigned driver and a Manager
 * (order_messages + send_order_message(); migrations 0018/0019, narrowed in
 * 0034). There used to be a second 'factory' channel, closed when factories
 * stopped being accounts — old factory messages stay readable by a Manager
 * as history, but nothing writes to that channel any more, and Moderators
 * are no longer part of these conversations at all (they see no messages;
 * the RLS policy, not just this component, is what enforces that).
 *
 * No realtime channel: this app doesn't use Supabase Realtime anywhere
 * else, so a short poll while the panel is open follows the same
 * architecture as the rest of the app (RPC writes, revalidated/refetched
 * reads) instead of introducing a new pattern that nothing here has been
 * verified against. Polling pauses while the tab is hidden
 * (document.visibilitychange) and catches up immediately when it becomes
 * visible again, instead of burning a request every 4s in a background tab
 * nobody is looking at.
 */
export function OrderChat({
  orderId,
  channel,
  viewerId,
}: {
  orderId: string;
  channel: OrderChatChannel;
  viewerId: string;
}) {
  const [messages, setMessages] = useState<OrderMessage[]>([]);
  const [loaded, setLoaded] = useState(false);
  const [draft, setDraft] = useState("");
  const [pending, startTransition] = useTransition();
  const listRef = useRef<HTMLDivElement>(null);
  const lastCountRef = useRef(0);
  const panelRef = useRef<HTMLDivElement>(null);

  // Bumped to reset the backoff to its fastest step — see quickenPolling().
  const [pollEpoch, setPollEpoch] = useState(0);
  const quickenPolling = useCallback(() => setPollEpoch((n) => n + 1), []);

  useEffect(() => {
    let cancelled = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    let step = 0;
    let lastSignature = "";
    // The panel sits below the order's actions, so it is frequently mounted
    // but off-screen. Assume visible until the observer says otherwise, so a
    // browser without IntersectionObserver behaves exactly as before.
    let onScreen = true;

    async function poll() {
      if (document.hidden || !onScreen) return;
      const res = await listOrderMessagesAction(orderId, channel);
      if (cancelled || !res.ok) return;

      setMessages(res.data);
      setLoaded(true);

      // Anything new resets the cadence; an unchanged thread steps it down.
      const signature = `${res.data.length}:${res.data[res.data.length - 1]?.id ?? ""}`;
      if (signature !== lastSignature) {
        lastSignature = signature;
        step = 0;
      } else if (step < POLL_LADDER_MS.length - 1) {
        step += 1;
      }
    }

    function schedule() {
      clearTimeout(timer);
      const delay = document.hidden || !onScreen ? POLL_IDLE_MS : POLL_LADDER_MS[step];
      timer = setTimeout(async () => {
        await poll();
        if (!cancelled) schedule();
      }, delay);
    }

    function onVisibility() {
      if (!document.hidden) {
        step = 0;
        void poll().then(() => !cancelled && schedule());
      }
    }

    // First load is immediate, exactly as before.
    void poll().then(() => !cancelled && schedule());
    document.addEventListener("visibilitychange", onVisibility);

    let observer: IntersectionObserver | undefined;
    const node = panelRef.current;
    if (node && typeof IntersectionObserver !== "undefined") {
      onScreen = false;
      observer = new IntersectionObserver(
        (entries) => {
          const nowOnScreen = entries.some((e) => e.isIntersecting);
          if (nowOnScreen && !onScreen) {
            // Scrolled into view — catch up right away.
            onScreen = true;
            step = 0;
            void poll().then(() => !cancelled && schedule());
          } else {
            onScreen = nowOnScreen;
          }
        },
        { rootMargin: "200px" },
      );
      observer.observe(node);
    }

    return () => {
      cancelled = true;
      clearTimeout(timer);
      document.removeEventListener("visibilitychange", onVisibility);
      observer?.disconnect();
    };
  }, [orderId, channel, pollEpoch]);

  useEffect(() => {
    if (messages.length !== lastCountRef.current) {
      lastCountRef.current = messages.length;
      listRef.current?.scrollTo({ top: listRef.current.scrollHeight, behavior: "smooth" });
    }
  }, [messages]);

  function submit() {
    const body = draft.trim();
    if (!body || pending) return;
    startTransition(async () => {
      const res = await sendOrderMessageAction(orderId, channel, body);
      if (!res.ok) {
        toast.error(res.error);
        return;
      }
      setDraft("");
      // Optimistic append — the next poll will reconcile with the server copy.
      setMessages((prev) => [...prev, res.data]);
      // A reply is most likely right after you send, so go back to checking
      // frequently instead of staying on a backed-off interval.
      quickenPolling();
    });
  }

  function onKeyDown(e: React.KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      submit();
    }
  }

  return (
    <Card ref={panelRef}>
      <CardHeader>
        <CardTitle className="flex items-center gap-1.5 text-base">
          <MessageCircle className="size-4" />
          {CHANNEL_TITLES_AR[channel]}
        </CardTitle>
      </CardHeader>
      <CardContent className="space-y-3 pt-0">
        <div ref={listRef} className="max-h-72 space-y-2 overflow-y-auto rounded-lg border bg-muted/20 p-2">
          {!loaded ? (
            <p className="p-3 text-center text-sm text-muted-foreground">جارِ تحميل الرسائل...</p>
          ) : messages.length === 0 ? (
            <p className="p-3 text-center text-sm text-muted-foreground">لا توجد رسائل بعد — ابدأ المحادثة.</p>
          ) : (
            messages.map((m) => {
              const mine = m.sender_id === viewerId;
              return (
                <div key={m.id} className={`flex ${mine ? "justify-start" : "justify-end"}`}>
                  <div
                    className={`max-w-[80%] rounded-lg px-3 py-2 text-sm ${
                      mine ? "bg-primary text-primary-foreground" : "bg-background border"
                    }`}
                  >
                    <p className="text-[11px] font-medium opacity-80">
                      {m.sender?.full_name ?? ROLE_LABELS_AR[m.sender_role] ?? m.sender_role}
                      {" · "}
                      {ROLE_LABELS_AR[m.sender_role] ?? m.sender_role}
                    </p>
                    <p className="whitespace-pre-wrap break-words">{m.body}</p>
                    <p className="mt-1 text-[10px] opacity-70">{formatRelative(m.created_at)}</p>
                  </div>
                </div>
              );
            })
          )}
        </div>
        <div className="flex items-end gap-2">
          <Textarea
            value={draft}
            onChange={(e) => setDraft(e.target.value)}
            onKeyDown={onKeyDown}
            placeholder="اكتب رسالة..."
            rows={2}
            className="resize-none"
            disabled={pending}
          />
          <Button size="icon" onClick={submit} disabled={pending || !draft.trim()} title="إرسال">
            {pending ? <Loader2 className="animate-spin" /> : <Send className="size-4" />}
          </Button>
        </div>
      </CardContent>
    </Card>
  );
}
