import { RootShell } from "@/components/root-shell";
import { siteMetadata } from "@/lib/meta";

/** Root layout of the Chinese site (`/zh`, `/zh/changelog`): `<html lang="zh-CN">`. The English one is app/(en)/layout.tsx. */
export const metadata = siteMetadata("zh");

export default function ChineseLayout({ children }: { children: React.ReactNode }) {
  return <RootShell lang="zh">{children}</RootShell>;
}
