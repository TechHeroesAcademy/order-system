import type { MetadataRoute } from "next";

/**
 * Web app manifest — makes the site installable as a PWA (Android "Add to
 * Home Screen" / desktop Chrome install, plus the iOS home-screen metadata
 * added separately via apple-icon.png + appleWebApp in layout.tsx, since
 * iOS Safari doesn't act on most of this file).
 *
 * theme_color matches the brand red used in the app icon/logo (not the
 * DHL-yellow --primary token), since this is what tints the OS status
 * bar / task switcher around the installed icon — it should read as
 * "EL REWAD", not as the in-app accent color.
 */
export default function manifest(): MetadataRoute.Manifest {
  return {
    name: "EL REWAD — نظام إدارة الأوردرات",
    short_name: "EL REWAD",
    description:
      "نظام داخلي لإدارة أوردرات تجديد أواني الطهي وتوزيعها وتتبعها من العميل إلى المصنع ورجوعًا.",
    start_url: "/",
    display: "standalone",
    orientation: "portrait",
    background_color: "#fefaf2",
    theme_color: "#C50211",
    dir: "rtl",
    lang: "ar",
    icons: [
      {
        src: "/icons/icon-192.png",
        sizes: "192x192",
        type: "image/png",
        purpose: "any",
      },
      {
        src: "/icons/icon-512.png",
        sizes: "512x512",
        type: "image/png",
        purpose: "any",
      },
      {
        src: "/icons/icon-512-maskable.png",
        sizes: "512x512",
        type: "image/png",
        purpose: "maskable",
      },
    ],
  };
}
