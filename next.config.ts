import type { NextConfig } from "next";

const nextConfig: NextConfig = {
  images: {
    // The professional hero photo on the homepage/login/setup pages
    // (warehouse + stock shelves, replacing the old cartoon illustration)
    // is hotlinked from Pexels rather than committed to the repo — real
    // photography, kept out of version control, served/optimized through
    // next/image the normal way. Free for commercial use under the Pexels
    // License: https://www.pexels.com/license/
    remotePatterns: [
      {
        protocol: "https",
        hostname: "images.pexels.com",
      },
    ],
  },
};

export default nextConfig;
