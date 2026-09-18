import type { NextConfig } from "next";

// The homepage/login/setup hero (see components/shared/hero-background.tsx)
// used to hotlink a Pexels warehouse photo through next/image, which is why
// this file used to carry an images.remotePatterns entry for
// images.pexels.com. It's now a self-contained animated SVG scene (drifting
// cooking pots) with no remote image, so there's nothing left needing a
// remote pattern — left this file otherwise empty rather than deleting it,
// since the next entry someone adds here will likely need the same shape.
const nextConfig: NextConfig = {};

export default nextConfig;
