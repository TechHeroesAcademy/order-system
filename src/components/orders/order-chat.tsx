"use client";

import { useEffect, useRef, useState, useTransition } from "react";
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

const POLL_INTERVAL_MS = 4000;

/**
 * One of the two independent per-order chat channels (migrations
 * 0018/0019 — order_messages + send_order_message()): 'driver' (the
 * assigned driver <-> Owner/Moderator) or 'factory' (the assigned factory
 * <-> Owner/Moderator). No realtime channel: this app doesn't use Supabase
 * Realtime anywhere else, so a short poll while the panel is open follows
 * the same architecture as the rest of the app (RPC writes,
 * revalidated/refetched reads) instead of introducing a new pattern that
 * nothing here has been verified against. Polling pauses while the tab is
 * hidden (document.visibilitychange) and catches up immediately when it
 * becomes visible again, instead of burning a request every 4s in a
 * background tab nobody is looking at.
 *
 * Rendered for Owner/Moderator on the order-detail page (both channels,
 * always — they can always message either side, even before a driver or
 * factory is assigned), for the assigned driver on their own order page
 * (driver channel only), and for the assigned factory on their own order
 * page (factory channel only). The two channels are genuinely separate
 * conversations — a driver can never see the factory channel and vice
 * versa, enforced by the RPC/RLS, not just by what this component renders.
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

  useEffect(() => {
    let cancelled = false;

    async function poll() {
      if (document.hidden) return;
      const res = await listOrderMessagesAction(orderId, channel);
      if (cancelled || !res.ok) return;
      setMessages(res.data);
      setLoaded(true);
    }

    poll();
    const interval = setInterval(poll, POLL_INTERVAL_MS);
    document.addEventListener("visibilitychange", poll);
    return () => {
      cancelled = true;
      clearInterval(interval);
      document.removeEventListener("visibilitychange", poll);
    };
  }, [orderId, channel]);

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
    });
  }

  function onKeyDown(e: React.KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === "Enter" && !e.shiftKey) {
      e.preventDefault();
      submit();
    }
  }

  return (
    <Card>
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
