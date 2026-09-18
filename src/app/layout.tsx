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
    // "black-translucent" lets content draw under the iOS status bar, which
    // is why viewportFit is already "cover" below (safe-area insets handle
    // the rest app-wide).
    statusBarStyle: "black-translucent",
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
