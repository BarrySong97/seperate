import { dict } from "@/i18n";
import { pageMetadata } from "@/lib/meta";
import { Changelog } from "@/views/changelog";

const t = dict("en").changelog;
export const metadata = pageMetadata("en", "/changelog", { title: t.title, description: t.description });

export default function Page() {
  return <Changelog lang="en" />;
}
