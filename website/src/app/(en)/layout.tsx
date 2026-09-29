import { RootShell } from "@/components/root-shell";
import { siteMetadata } from "@/lib/meta";

/** Root layout of the English site (`/`, `/changelog`): `<html lang="en">`. The Chinese one is app/(zh)/layout.tsx. */
export const metadata = siteMetadata("en");

export default function EnglishLayout({ children }: { children: React.ReactNode }) {
  return <RootShell lang="en">{children}</RootShell>;
}
