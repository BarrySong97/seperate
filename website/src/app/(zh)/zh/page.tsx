import { pageMetadata } from "@/lib/meta";
import { Home } from "@/views/home";

export const metadata = pageMetadata("zh", "/");

export default function Page() {
  return <Home lang="zh" />;
}
