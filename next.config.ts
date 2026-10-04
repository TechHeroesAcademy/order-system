import type { NextConfig } from "next";

// The homepage/login/setup hero (see components/shared/hero-background.tsx)
// used to hotlink a Pexels warehouse photo through next/image, which is why
// this file used to carry an images.remotePatterns entry for
// images.pexels.com. It's now a self-contained animated SVG scene (drifting
// cooking pots) with no remote image, so there's nothing left needing a
// remote pattern.
const nextConfig: NextConfig = {
  /**
   * Security headers. The app sent none of these before.
   *
   * Each one is here because of something specific this app does, not from a
   * checklist — and the two that usually break a working site are tuned to
   * what it actually loads.
   */
  async headers() {
    const csp = [
      "default-src 'self'",
      // 'unsafe-inline' for styles because Tailwind's JIT and the inline
      // style attributes React writes both need it. 'unsafe-eval' is NOT
      // here, so a string passed to eval() or new Function() will not run.
      "style-src 'self' 'unsafe-inline'",
      // Next's App Router inlines a bootstrap script and the streamed RSC
      // payload as inline <script> tags, so this cannot be tightened without
      // nonces threaded through every response. Worth revisiting; stated
      // plainly rather than pretended about.
      "script-src 'self' 'unsafe-inline'",
      // Leaflet pulls map tiles from OpenStreetMap, and the pins are data:
      // URIs. Without these two the maps go blank.
      "img-src 'self' data: blob: https://*.tile.openstreetmap.org",
      "font-src 'self' data:",
      // Same-origin only: Server Actions and the push subscription both post
      // back here. No third-party analytics, no error reporter, nothing else
      // to allow — so anything exfiltrating data has nowhere to send it.
      "connect-src 'self'",
      // The app is never meant to be framed, and these two are what stop a
      // lookalike site from wrapping it to harvest a login.
      "frame-ancestors 'none'",
      "frame-src 'none'",
      "object-src 'none'",
      "base-uri 'self'",
      // Stops a form on an injected page from posting credentials elsewhere.
      "form-action 'self'",
      "upgrade-insecure-requests",
    ].join("; ");

    return [
      {
        source: "/:path*",
        headers: [
          { key: "Content-Security-Policy", value: csp },
          // Two years, with preload eligibility. Drivers open this on phones
          // over mobile networks, which is exactly where a downgrade to
          // plain HTTP would be injected.
          {
            key: "Strict-Transport-Security",
            value: "max-age=63072000; includeSubDomains; preload",
          },
          // Redundant with frame-ancestors for modern browsers, kept for
          // older ones that only understand this.
          { key: "X-Frame-Options", value: "DENY" },
          { key: "X-Content-Type-Options", value: "nosniff" },
          // Order numbers and ids appear in paths, so a full referrer would
          // hand them to any site a driver taps through to — including the
          // Google Maps links on every order.
          { key: "Referrer-Policy", value: "strict-origin-when-cross-origin" },
          // Nothing in the app uses any of these.
          {
            key: "Permissions-Policy",
            value: "camera=(), microphone=(), geolocation=(), payment=(), usb=()",
          },
          { key: "X-DNS-Prefetch-Control", value: "off" },
        ],
      },
      {
        // The service worker must not be cached across deploys, or a phone
        // keeps an old one and push stops arriving after an update.
        source: "/sw.js",
        headers: [
          { key: "Cache-Control", value: "no-cache, no-store, must-revalidate" },
          { key: "Service-Worker-Allowed", value: "/" },
        ],
      },
    ];
  },
  experimental: {
    // Every <Link> in the app prefetches by default (on hover/viewport), and
    // the auth proxy runs on prefetch requests too — so each prefetch costs a
    // verified auth call plus a profile lookup. With five nav links rendered
    // on every authenticated screen, simply landing on a dashboard fired a
    // handful of extra round-trips before the user clicked anything.
    //
    // dynamic defaults to 0 (never reuse), which means moving back and forth
    // between two screens re-fetches both every time. 30s means a
    // click-around within half a minute reuses what's already in the client
    // cache. It does NOT make data stale after your own edits: a Server
    // Action's revalidatePath, and the router.refresh() the mutation
    // components call, both clear this cache — so anything you change, you
    // see immediately. It only affects passive navigation.
    staleTimes: {
      dynamic: 30,
      static: 180,
    },
    // lucide-react is imported by name in ~50 files and @radix-ui ships a
    // package per primitive; this pulls in only the modules actually used
    // instead of the whole barrel, which shrinks the shared chunk every page
    // downloads.
    optimizePackageImports: [
      "lucide-react",
      "date-fns",
      "@radix-ui/react-alert-dialog",
      "@radix-ui/react-avatar",
      "@radix-ui/react-checkbox",
      "@radix-ui/react-dialog",
      "@radix-ui/react-dropdown-menu",
      "@radix-ui/react-label",
      "@radix-ui/react-popover",
      "@radix-ui/react-scroll-area",
      "@radix-ui/react-select",
      "@radix-ui/react-separator",
      "@radix-ui/react-slot",
      "@radix-ui/react-tabs",
      "@radix-ui/react-toast",
    ],
  },
};

export default nextConfig;
