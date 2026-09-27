import type { MetadataRoute } from "next";
import { getReleases } from "@/lib/changelog";
import { site } from "@/lib/site";

export const dynamic = "force-static";

export default function sitemap(): MetadataRoute.Sitemap {
  // The newest release date (patches included) is when either page last changed in a way that matters.
  const [newest] = getReleases();
  const lastModified = newest?.patches[0]?.date ?? newest?.date;
  return [
    { url: site.url, lastModified, changeFrequency: "weekly", priority: 1 },
    { url: `${site.url}/changelog`, lastModified, changeFrequency: "weekly", priority: 0.7 },
  ];
}
