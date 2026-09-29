import { AppWindowMock } from "@/components/mocks";
import { VideoPlayer } from "@/components/video-player";
import { dict, type Lang } from "@/i18n";

/**
 * The homepage hero: the demo video in the site's player. It does not autoplay: visitors see the
 * poster and a play button, and pressing play starts it from the top with sound.
 * Without a video yet (site.heroVideo.src empty), a still of the app stands in.
 */
export function HeroVideo({ src, poster, lang }: { src: string; poster?: string; lang: Lang }) {
  if (src) {
    return (
      <VideoPlayer
        src={src}
        poster={poster || undefined}
        label={dict(lang).home.demoLabel}
        soundButton
        autoPlay={false}
        className="aspect-video rounded-2xl shadow-[0_40px_120px_-40px_rgba(0,0,0,0.8)]"
      />
    );
  }
  return (
    <div className="relative aspect-video w-full overflow-hidden rounded-2xl border border-line bg-sunk shadow-[0_40px_120px_-40px_rgba(0,0,0,0.8)]">
      <div className="absolute inset-[6%_6%_8%]">
        <AppWindowMock lang={lang} />
      </div>
    </div>
  );
}
