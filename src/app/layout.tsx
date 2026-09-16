import type { Metadata, Viewport } from "next";
import { Toaster } from "@/components/ui/sonner";
import { RefreshToHome } from "@/components/layout/refresh-to-home";
import "./globals.css";

export const metadata: Metadata = {
  title: "شركة المجد لإدارة الأوردرات",
  description: "نظام داخلي لإدارة الأوردرات وتوزيعها وتتبعها من العميل إلى المصنع ورجوعًا — شركة المجد.",
};

export const viewport: Viewport = {
  width: "device-width",
  initialScale: 1,
  viewportFit: "cover",
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
