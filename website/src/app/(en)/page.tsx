import { pageMetadata } from "@/lib/meta";
import { Home } from "@/views/home";

export const metadata = pageMetadata("en", "/");

export default function Page() {
  return <Home lang="en" />;
}
