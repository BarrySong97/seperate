"use client";

/**
 * Video in the site's style. By default it plays muted and looping while on screen, like a moving
 * screenshot, and pauses when scrolled away. Hover or focus shows the controls: play/pause, scrub,
 * time, sound, fullscreen. With `soundButton`, a "play with sound" pill restarts it from the top with sound.
 * People who ask for reduced motion get a paused first frame with a play button instead of autoplay.
 * With `autoPlay={false}` it waits on its poster with a play button; the first play starts from the
 * top with sound (so the "play with sound" pill is not shown).
 */
import { useEffect, useRef, useState } from "react";
import { cn } from "@/lib/cn";
import { useDict } from "@/i18n/client";

type Props = {
  src: string;
  poster?: string;
  caption?: string;
  label?: string;
  soundButton?: boolean;
  autoPlay?: boolean;
  className?: string;
};

function time(s: number) {
  if (!Number.isFinite(s)) return "0:00";
  const m = Math.floor(s / 60);
  return `${m}:${String(Math.floor(s % 60)).padStart(2, "0")}`;
}

const Icon = {
  play: <path d="M8 5.5v13l11-6.5z" fill="currentColor" />,
  pause: <path d="M7 5h3.5v14H7zM13.5 5H17v14h-3.5z" fill="currentColor" />,
  muted: <path d="M4 9h4l5-4v14l-5-4H4zM16 9l5 6M21 9l-5 6" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />,
  sound: <path d="M4 9h4l5-4v14l-5-4H4zM16.5 8.5a5 5 0 0 1 0 7M19 6a8.5 8.5 0 0 1 0 12" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />,
  expand: <path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round" />,
};

function Svg({ children, className = "size-4" }: { children: React.ReactNode; className?: string }) {
  return (
    <svg className={className} viewBox="0 0 24 24" aria-hidden="true">
      {children}
    </svg>
  );
}

export function VideoPlayer({ src, poster, caption, label, soundButton, autoPlay = true, className }: Props) {
  const t = useDict().video;
  const box = useRef<HTMLDivElement>(null);
  const video = useRef<HTMLVideoElement>(null);
  const [playing, setPlaying] = useState(false);
  const [muted, setMuted] = useState(true);
  const [now, setNow] = useState(0);
  const [duration, setDuration] = useState(0);
  const [touched, setTouched] = useState(false); // the viewer took over: stop auto play/pause on scroll
  const [reduced, setReduced] = useState(false);
  const scrubbing = useRef(false); // while dragging the bar, playback time updates don't move the thumb

  // The browser can read the metadata before React hydrates, so onLoadedMetadata never fires and the
  // bar would stay at length 0. Pick up whatever is already known.
  useEffect(() => {
    const v = video.current;
    if (v && v.readyState >= 1) setDuration(v.duration);
  }, []);

  // Play while visible, pause when scrolled away, until the viewer uses the controls.
  useEffect(() => {
    const v = video.current;
    if (!v) return;
    const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
    setReduced(reduce);
    if (reduce || touched || !autoPlay) return;
    const io = new IntersectionObserver(([entry]) => {
      if (entry.isIntersecting) void v.play().catch(() => {});
      else v.pause();
    }, { threshold: 0.35 });
    io.observe(v);
    return () => io.disconnect();
  }, [touched, autoPlay]);

  const toggle = () => {
    const v = video.current;
    if (!v) return;
    setTouched(true);
    if (v.paused) void v.play();
    else v.pause();
  };

  const toggleMute = () => {
    const v = video.current;
    if (!v) return;
    v.muted = !v.muted;
    setMuted(v.muted);
  };

  const playWithSound = () => {
    const v = video.current;
    if (!v) return;
    setTouched(true);
    v.currentTime = 0;
    v.muted = false;
    v.loop = false;
    setMuted(false);
    void v.play();
  };

  // Without autoplay, the viewer's first play is the real start: from the top, with sound.
  const play = () => (!autoPlay && !touched ? playWithSound() : toggle());

  const seek = (value: number) => {
    const v = video.current;
    if (!v || !duration) return;
    v.currentTime = value;
    setNow(value);
  };

  const endScrub = () => {
    scrubbing.current = false;
  };

  const fullscreen = () => {
    const el = box.current;
    if (!el) return;
    if (document.fullscreenElement) void document.exitFullscreen();
    else void el.requestFullscreen?.().catch(() => {});
  };

  const controlButton = "flex size-8 items-center justify-center rounded-full text-cta transition-colors hover:bg-white/15";

  return (
    <figure className="flex flex-col gap-2.5">
      <div
        ref={box}
        className={cn(
          "group relative overflow-hidden rounded-xl border border-line bg-sunk [&:fullscreen]:rounded-none [&:fullscreen]:border-0",
          className,
        )}
      >
        <video
          ref={video}
          className="block size-full cursor-pointer object-cover"
          src={src}
          poster={poster}
          muted
          loop={autoPlay}
          playsInline
          preload="metadata"
          aria-label={label ?? caption}
          onClick={play}
          onPlay={() => setPlaying(true)}
          onPause={() => setPlaying(false)}
          onTimeUpdate={(e) => {
            if (!scrubbing.current) setNow(e.currentTarget.currentTime);
          }}
          onLoadedMetadata={(e) => setDuration(e.currentTarget.duration)}
          onDurationChange={(e) => setDuration(e.currentTarget.duration)}
          onEnded={() => setPlaying(false)}
        />

        {/* Paused (reduced motion, no autoplay, or stopped by the viewer): one big play button. */}
        {!playing && (reduced || touched || !autoPlay) && (
          <button
            type="button"
            onClick={play}
            aria-label={t.play}
            className="absolute top-1/2 left-1/2 flex size-18 -translate-x-1/2 -translate-y-1/2 items-center justify-center rounded-full bg-cta/90 text-ground shadow-lg transition-transform hover:scale-105"
          >
            <Svg className="size-7">{Icon.play}</Svg>
          </button>
        )}

        {soundButton && autoPlay && muted && (
          <button
            type="button"
            onClick={playWithSound}
            className="absolute top-4 left-4 flex items-center gap-2 rounded-full bg-cta/90 px-3.5 py-1.5 text-[13px] font-semibold text-ground shadow-lg backdrop-blur transition-colors hover:bg-white"
          >
            <Svg className="size-3.5">{Icon.sound}</Svg>
            {t.playWithSound}
          </button>
        )}

        <div
          className={cn(
            "absolute inset-x-0 bottom-0 flex items-center gap-2 bg-linear-to-t from-black/70 to-transparent px-3 pt-8 pb-2.5 transition-opacity duration-200",
            playing ? "opacity-0 group-hover:opacity-100 group-focus-within:opacity-100" : "opacity-100",
          )}
        >
          <button type="button" onClick={play} aria-label={playing ? t.pause : t.play} className={controlButton}>
            <Svg>{playing ? Icon.pause : Icon.play}</Svg>
          </button>
          <span className="w-20 shrink-0 font-mono text-[11px] text-cta/80 tabular-nums">
            {time(now)} / {time(duration)}
          </span>
          <input
            type="range"
            min={0}
            max={duration || 0}
            step={0.05}
            value={Math.min(now, duration || 0)}
            onPointerDown={() => {
              scrubbing.current = true;
            }}
            onPointerUp={endScrub}
            onPointerCancel={endScrub}
            onBlur={endScrub}
            onChange={(e) => {
              setTouched(true);
              seek(Number(e.target.value));
            }}
            aria-label={t.progress}
            disabled={!duration}
            style={{ "--p": `${duration ? (Math.min(now, duration) / duration) * 100 : 0}%` } as React.CSSProperties}
            className="h-1 min-w-0 flex-1 cursor-pointer appearance-none rounded-full bg-[linear-gradient(to_right,var(--color-cta)_var(--p),rgb(255_255_255/0.25)_var(--p))] accent-cta disabled:cursor-default [&::-moz-range-thumb]:size-3 [&::-moz-range-thumb]:rounded-full [&::-moz-range-thumb]:border-0 [&::-moz-range-thumb]:bg-cta [&::-webkit-slider-thumb]:size-3 [&::-webkit-slider-thumb]:appearance-none [&::-webkit-slider-thumb]:rounded-full [&::-webkit-slider-thumb]:bg-cta"
          />
          <button type="button" onClick={toggleMute} aria-label={muted ? t.unmute : t.mute} className={controlButton}>
            <Svg>{muted ? Icon.muted : Icon.sound}</Svg>
          </button>
          <button type="button" onClick={fullscreen} aria-label={t.fullscreen} className={controlButton}>
            <Svg>{Icon.expand}</Svg>
          </button>
        </div>
      </div>
      {caption && <figcaption className="text-center text-[13px] leading-relaxed text-faint">{caption}</figcaption>}
    </figure>
  );
}
