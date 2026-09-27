import type { NextConfig } from "next";

// Fully static site (out/): pages are prerendered at build time, media lives on Cloudflare R2.
const nextConfig: NextConfig = {
  output: "export",
  images: { unoptimized: true },
};

export default nextConfig;
