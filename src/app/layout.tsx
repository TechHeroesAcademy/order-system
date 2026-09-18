import type { Metadata, Viewport } from "next";
import { Toaster } from "@/components/ui/sonner";
import { RefreshToHome } from "@/components/layout/refresh-to-home";
import "./globals.css";

export const metadata: Metadata = {
  title: "EL REWAD — تجديد أواني الطهي",
  description:
    "نظام داخلي لإدارة أوردرات تجديد أواني الطهي وتوزيعها وتتبعها من العميل إلى المصنع ورجوعًا — EL REWAD Company.",
  // manifest.ts is an app-router special file and gets auto-linked, same as
  // icon.png/apple-icon.png below — this entry isn't required, but it's kept
  // explicit so the <link rel="manifest"> tag doesn't depend on that
  // auto-detection working the same way in this Next.js build.
  manifest: "/manifest.webmanifest",
  appleWebApp: {
    capable: true,
    title: "EL REWAD",
    // "default" (opaque status bar, iOS reserves its own space above the
    // page) — NOT "black-translucent". Translucent draws the page content
    // full-bleed *underneath* the status bar instead, and nothing in this
    // app was actually padding for that (no env(safe-area-inset-top)
    // anywhere), so the sticky AppShell header ended up rendering partly
    // behind the notch/status-bar icons the moment the app was opened from
    // the home screen — that's the "header disappeared" report. "default"
    // makes iOS handle the reserved space itself, no CSS needed.
    statusBarStyle: "default",
  },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
  // Matches the manifest's theme_color (the brand red from the app icon),
  // so the installed app's status bar and a plain browser tab's address
  // bar both tint the same way.
  themeColor: "#C50211",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ar" dir="rtl" className="h-full antialiased">
      <body className="min-h-full flex flex-col bg-background text-foreground">
        <RefreshToHome />
        {children}
        <Toaster />
      </body>
    </html>
  );
}
