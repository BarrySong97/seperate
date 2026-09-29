import type { NextConfig } from "next";

// Fully static site (out/): pages are prerendered at build time, media lives on Cloudflare R2.
const nextConfig: NextConfig = {
  output: "export",
  images: { unoptimized: true },
  // Two root layouts (app/(en), app/(zh)) leave no single layout for the 404 page; app/global-not-found.tsx is it.
  experimental: { globalNotFound: true },
};

export default nextConfig;
