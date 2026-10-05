import type { Metadata, Viewport } from "next";
import { Toaster } from "@/components/ui/sonner";
import { RefreshToHome } from "@/components/layout/refresh-to-home";
import "./globals.css";

export const metadata: Metadata = {
  title: "EL REWAD — تجديد أواني الطهي",
  description:
    "نظام داخلي لإدارة أوردرات تجديد أواني الطهي وتوزيعها وتتبعها من العميل إلى المصنع ورجوعًا — EL REWAD Company.",
  manifest: "/manifest.webmanifest",
  appleWebApp: {
    capable: true,
    title: "EL REWAD",
    statusBarStyle: "default",
  },
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
  themeColor: "#C50211",
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="ar" dir="rtl" className="h-full antialiased">
      <body className="min-h-full flex flex-col bg-background text-foreground">
        <RefreshToHome />
        {children}
        <footer className="shrink-0 py-3 text-center text-[10px] leading-none text-muted-foreground/60">
          developed by NonZeroExitAli
        </footer>
        <Toaster />
      </body>
    </html>
  );
}
