import type { NextConfig } from "next";

// The homepage/login/setup hero (see components/shared/hero-background.tsx)
// used to hotlink a Pexels warehouse photo through next/image, which is why
// this file used to carry an images.remotePatterns entry for
// images.pexels.com. It's now a self-contained animated SVG scene (drifting
// cooking pots) with no remote image, so there's nothing left needing a
// remote pattern.
const nextConfig: NextConfig = {
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
