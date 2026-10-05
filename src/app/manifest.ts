import type { MetadataRoute } from "next";

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
