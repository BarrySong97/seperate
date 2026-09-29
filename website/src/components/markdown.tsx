import ReactMarkdown, { defaultUrlTransform, type Components } from "react-markdown";
import remarkGfm from "remark-gfm";
import { ChangelogMock } from "@/components/changelog-mocks";
import { VideoPlayer } from "@/components/video-player";
import type { Lang } from "@/i18n";
import { ZoomImage } from "@/components/zoom-image";

const isVideo = (src: string) => /\.(mp4|webm|mov)(\?|$)/i.test(src);

export type MediaProps = {
  src: string;
  alt?: string;
  caption?: string;
  poster?: string;
  width?: number;
  height?: number;
  thumbhash?: string;
};

/** A video (.mp4/.webm/.mov) gets the site's player; anything else is a zoomable image.
 *  In Markdown, the alt text doubles as the caption under it. */
export function Media({ src, alt, caption, poster, width, height, thumbhash }: MediaProps) {
  if (isVideo(src)) return <VideoPlayer src={src} poster={poster} caption={caption} label={alt} />;
  return <ZoomImage src={src} alt={alt} caption={caption} width={width} height={height} thumbhash={thumbhash} />;
}

/** `pnpm upload` puts "1920x1080 <thumbhash>" in the Markdown image title: size and blur placeholder. */
function fromTitle(title?: string | null) {
  const [size, thumbhash] = (title ?? "").trim().split(/\s+/);
  const m = size?.match(/^(\d+)x(\d+)$/);
  return m ? { width: Number(m[1]), height: Number(m[2]), thumbhash } : {};
}

// Per language: `mock:` drawings show the app's UI in the page's language.
const components = (lang: Lang): Components => ({
  // Cursor-like reading rhythm: sans headings, 16px body, air before each section.
  h2: ({ children }) => <h3 className="mt-8 text-[22px] leading-snug font-semibold tracking-[-0.01em] text-ink">{children}</h3>,
  h3: ({ children }) => <h3 className="mt-8 text-[22px] leading-snug font-semibold tracking-[-0.01em] text-ink">{children}</h3>,
  // "#### Improvements" / "#### Fixes" (改进 / 修复): small headings for the short lists
  h4: ({ children }) => <h4 className="mt-6 text-base font-semibold text-text">{children}</h4>,
  p: ({ children, node }) => {
    // An image on its own line becomes a block, not an image inside a paragraph.
    const only = node?.children.length === 1 && node.children[0].type === "element" && node.children[0].tagName === "img";
    return only ? <>{children}</> : <p className="text-base leading-[1.7] text-body">{children}</p>;
  },
  ul: ({ children }) => <ul className="flex list-disc flex-col gap-2 pl-5 text-base leading-[1.7] text-body marker:text-faint">{children}</ul>,
  ol: ({ children }) => <ol className="flex list-decimal flex-col gap-2 pl-5 text-base leading-[1.7] text-body marker:text-faint">{children}</ol>,
  a: ({ children, href }) => (
    <a href={href} className="text-text underline decoration-line-strong underline-offset-4 hover:decoration-muted">
      {children}
    </a>
  ),
  code: ({ children }) => (
    <code className="rounded border border-line bg-panel px-1.5 py-px font-mono text-[0.875em] text-text">{children}</code>
  ),
  strong: ({ children }) => <strong className="font-semibold text-text">{children}</strong>,
  img: ({ src, alt, title }) => {
    if (typeof src !== "string") return null;
    // `![caption](mock:tab-menu)`: a drawing of the app's UI from changelog-mocks.tsx.
    if (src.startsWith("mock:")) return <ChangelogMock name={src.slice(5)} caption={alt || undefined} lang={lang} />;
    return <Media src={src} alt={alt} caption={alt || undefined} {...fromTitle(title)} />;
  },
});

// Keep `mock:` sources; everything else gets react-markdown's usual URL sanitizing.
const urlTransform = (url: string) => (url.startsWith("mock:") ? url : defaultUrlTransform(url));

export function Markdown({ lang, children }: { lang: Lang; children: string }) {
  return (
    <div className="flex flex-col gap-4">
      <ReactMarkdown remarkPlugins={[remarkGfm]} components={components(lang)} urlTransform={urlTransform}>
        {children}
      </ReactMarkdown>
    </div>
  );
}
