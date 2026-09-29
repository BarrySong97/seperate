import { Fraunces, IBM_Plex_Mono, IBM_Plex_Sans, Noto_Serif_SC } from "next/font/google";
import { Footer } from "@/components/footer";
import { LangHint } from "@/components/lang-hint";
import { Nav } from "@/components/nav";
import { htmlLang, type Lang } from "@/i18n";
import { LangProvider } from "@/i18n/client";
import "@/app/globals.css";

/**
 * The <html> document shared by both languages' root layouts (app/(en)/layout.tsx, app/(zh)/layout.tsx):
 * fonts, nav, footer, and the language for client components. Each language is its own root layout so
 * `<html lang>` is right in the static HTML.
 */
const fraunces = Fraunces({ variable: "--font-fraunces", subsets: ["latin"], weight: ["500", "600"] });
const plexSans = IBM_Plex_Sans({ variable: "--font-plex-sans", subsets: ["latin"], weight: ["400", "500", "600"] });
const plexMono = IBM_Plex_Mono({ variable: "--font-plex-mono", subsets: ["latin"], weight: ["400", "500"] });
// Chinese headings. Large, so not preloaded; it swaps in over Songti / system serif.
const notoSerifSC = Noto_Serif_SC({ variable: "--font-noto-serif-sc", weight: ["700"], preload: false });

export function RootShell({ lang, children }: { lang: Lang; children: React.ReactNode }) {
  return (
    <html
      lang={htmlLang[lang]}
      className={`${fraunces.variable} ${plexSans.variable} ${plexMono.variable} ${notoSerifSC.variable} antialiased`}
    >
      <body className="flex min-h-dvh flex-col">
        <LangProvider lang={lang}>
          {lang === "en" && <LangHint />}
          <Nav />
          <main className="flex-1">{children}</main>
          <Footer lang={lang} />
        </LangProvider>
      </body>
    </html>
  );
}
