import type { Metadata } from "next";
import { Fraunces, IBM_Plex_Mono, IBM_Plex_Sans, Noto_Serif_SC } from "next/font/google";
import { Footer } from "@/components/footer";
import { Nav } from "@/components/nav";
import { site } from "@/lib/site";
import "./globals.css";

const fraunces = Fraunces({ variable: "--font-fraunces", subsets: ["latin"], weight: ["500", "600"] });
const plexSans = IBM_Plex_Sans({ variable: "--font-plex-sans", subsets: ["latin"], weight: ["400", "500", "600"] });
const plexMono = IBM_Plex_Mono({ variable: "--font-plex-mono", subsets: ["latin"], weight: ["400", "500"] });
// Chinese headings. Large, so not preloaded; it swaps in over Songti / system serif.
const notoSerifSC = Noto_Serif_SC({ variable: "--font-noto-serif-sc", weight: ["700"], preload: false });

export const metadata: Metadata = {
  metadataBase: new URL(site.url),
  title: { default: site.title, template: "%s · Seperate" },
  description: site.description,
  applicationName: site.name,
  keywords: site.keywords,
  authors: [{ name: "Barry Song", url: site.repo }],
  creator: "Barry Song",
  category: "developer tools",
  alternates: { canonical: "/" },
  robots: { index: true, follow: true },
  openGraph: {
    type: "website",
    locale: "zh_CN",
    siteName: site.name,
    url: "/",
    title: site.title,
    description: site.description,
  },
  twitter: { card: "summary_large_image", title: site.title, description: site.description },
};

export default function RootLayout({ children }: LayoutProps<"/">) {
  return (
    <html
      lang="zh-CN"
      className={`${fraunces.variable} ${plexSans.variable} ${plexMono.variable} ${notoSerifSC.variable} antialiased`}
    >
      <body className="flex min-h-dvh flex-col">
        <Nav />
        <main className="flex-1">{children}</main>
        <Footer />
      </body>
    </html>
  );
}
