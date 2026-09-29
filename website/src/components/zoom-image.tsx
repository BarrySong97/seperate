"use client";

/**
 * Image with blur-up loading and click-to-zoom. Ported from jade's BlogImage.
 * - thumbhash (from `pnpm upload`) paints the average color at once, then a blurred preview; the real
 *   image fades in over it once loaded.
 * - Click opens a lightbox: the image morphs from its place (Motion shared layout, `layoutId`),
 *   zoom 100–400% with the wheel, +/- keys or buttons, drag or arrow keys to pan, 0 resets, Esc closes.
 * Motion's shared-layout crossfade rewrites inline opacity every frame, so the thumbnail is held hidden
 * with !important classes until the closing morph finishes (onExitComplete); otherwise it ghosts.
 */
import { AnimatePresence, motion } from "motion/react";
import { useCallback, useEffect, useId, useMemo, useRef, useState } from "react";
import { thumbHashToAverageRGBA, thumbHashToDataURL } from "thumbhash";
import { cn } from "@/lib/cn";
import { useDict } from "@/i18n/client";

type Props = {
  src: string;
  alt?: string;
  caption?: string;
  width?: number;
  height?: number;
  thumbhash?: string;
  zoomable?: boolean;
  className?: string;
};

const MORPH = { duration: 0.36, ease: [0.22, 1, 0.36, 1] as const };
const MIN_ZOOM = 1;
const MAX_ZOOM = 4;
const STEP = 0.5;

type Point = { x: number; y: number };

function base64ToBytes(b64: string) {
  const bin = atob(b64);
  const bytes = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) bytes[i] = bin.charCodeAt(i);
  return bytes;
}

export function ZoomImage({ src, alt, caption, width, height, thumbhash, zoomable = true, className }: Props) {
  const t = useDict().zoom;
  const text = caption ?? alt ?? "";
  const [loaded, setLoaded] = useState(false);
  const [open, setOpen] = useState(false);
  const [exiting, setExiting] = useState(false);
  const [zoom, setZoom] = useState(MIN_ZOOM);
  const [pan, setPan] = useState<Point>({ x: 0, y: 0 });
  const [dragging, setDragging] = useState(false);
  const imgRef = useRef<HTMLImageElement>(null);
  const dragRef = useRef<{ id: number; start: Point; pan: Point } | null>(null);
  const layoutId = useId();

  const placeholder = useMemo(() => {
    if (!thumbhash) return null;
    try {
      const bytes = base64ToBytes(thumbhash);
      const { r, g, b, a } = thumbHashToAverageRGBA(bytes);
      return { avg: `rgba(${Math.round(r * 255)}, ${Math.round(g * 255)}, ${Math.round(b * 255)}, ${a})`, url: thumbHashToDataURL(bytes) };
    } catch {
      return null;
    }
  }, [thumbhash]);

  const clampPan = useCallback((p: Point, scale: number): Point => {
    if (scale <= MIN_ZOOM) return { x: 0, y: 0 };
    const bx = (window.innerWidth * (scale - 1)) / 2;
    const by = (window.innerHeight * (scale - 1)) / 2;
    return { x: Math.max(-bx, Math.min(bx, p.x)), y: Math.max(-by, Math.min(by, p.y)) };
  }, []);

  const changeZoom = useCallback(
    (delta: number) => {
      setZoom((z) => {
        const next = Math.max(MIN_ZOOM, Math.min(MAX_ZOOM, z + delta));
        setPan((p) => clampPan(p, next));
        return next;
      });
    },
    [clampPan],
  );

  const reset = useCallback(() => {
    setZoom(MIN_ZOOM);
    setPan({ x: 0, y: 0 });
  }, []);

  const close = useCallback(() => {
    setOpen(false);
    setExiting(true);
  }, []);

  // Already cached before hydration counts as loaded too.
  useEffect(() => {
    const img = imgRef.current;
    if (!img) return;
    if (img.complete && img.naturalWidth > 0) return setLoaded(true);
    const onLoad = () => setLoaded(true);
    img.addEventListener("load", onLoad);
    return () => img.removeEventListener("load", onLoad);
  }, [src]);

  useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") close();
      else if (e.key === "+" || e.key === "=") changeZoom(STEP);
      else if (e.key === "-") changeZoom(-STEP);
      else if (e.key === "0") reset();
      else if (e.key.startsWith("Arrow")) {
        const s = e.shiftKey ? 80 : 40;
        const d = { ArrowLeft: [-s, 0], ArrowRight: [s, 0], ArrowUp: [0, -s], ArrowDown: [0, s] }[e.key] ?? [0, 0];
        setPan((p) => clampPan({ x: p.x + d[0], y: p.y + d[1] }, zoom));
      }
    };
    document.addEventListener("keydown", onKey);
    const overflow = document.body.style.overflow;
    document.body.style.overflow = "hidden";
    return () => {
      document.removeEventListener("keydown", onKey);
      document.body.style.overflow = overflow;
    };
  }, [open, zoom, close, changeZoom, reset, clampPan]);

  const onPointerDown = (e: React.PointerEvent<HTMLImageElement>) => {
    if (zoom <= MIN_ZOOM) return;
    e.preventDefault();
    e.currentTarget.setPointerCapture(e.pointerId);
    dragRef.current = { id: e.pointerId, start: { x: e.clientX, y: e.clientY }, pan };
    setDragging(true);
  };
  const onPointerMove = (e: React.PointerEvent<HTMLImageElement>) => {
    const d = dragRef.current;
    if (!d || d.id !== e.pointerId) return;
    setPan(clampPan({ x: d.pan.x + e.clientX - d.start.x, y: d.pan.y + e.clientY - d.start.y }, zoom));
  };
  const onPointerUp = (e: React.PointerEvent<HTMLImageElement>) => {
    if (dragRef.current?.id !== e.pointerId) return;
    if (e.currentTarget.hasPointerCapture(e.pointerId)) e.currentTarget.releasePointerCapture(e.pointerId);
    dragRef.current = null;
    setDragging(false);
  };

  const hidden = open || exiting;
  const iconButton = "size-9 rounded-full text-lg transition-colors hover:bg-white/15 disabled:cursor-not-allowed disabled:opacity-35";

  return (
    <>
      <figure className="flex flex-col gap-2.5">
        <div
          className={cn("relative overflow-hidden rounded-xl border border-line bg-sunk", className)}
          style={{
            aspectRatio: width && height ? `${width}/${height}` : undefined,
            backgroundColor: hidden ? undefined : placeholder?.avg,
            backgroundImage: placeholder && !hidden ? `url(${placeholder.url})` : undefined,
            backgroundSize: "cover",
            backgroundPosition: "center",
          }}
        >
          <motion.img
            ref={imgRef}
            layoutId={layoutId}
            src={src}
            alt={text}
            width={width}
            height={height}
            loading="lazy"
            decoding="async"
            draggable={false}
            onClick={zoomable ? () => setOpen(true) : undefined}
            className={cn(
              "block h-full w-full object-cover transition-opacity duration-700 ease-out",
              loaded ? "opacity-100" : "opacity-0",
              zoomable && "cursor-zoom-in",
              hidden && "invisible! opacity-100!",
            )}
          />
        </div>
        {caption && <figcaption className="text-center text-[13px] leading-relaxed text-faint">{caption}</figcaption>}
      </figure>

      <AnimatePresence
        onExitComplete={() => {
          setExiting(false);
          reset();
        }}
      >
        {open && (
          <motion.div
            key="lightbox"
            className="fixed inset-0 z-50 flex items-center justify-center overflow-hidden p-4"
            role="dialog"
            aria-modal="true"
            aria-label={t.viewer}
            onWheel={(e) => changeZoom(e.deltaY > 0 ? -STEP : STEP)}
            onClick={close}
          >
            {/* The backdrop fades on its own, so the closing image stays solid while it morphs back. */}
            <motion.div
              className="absolute inset-0 bg-black/90"
              initial={{ opacity: 0 }}
              animate={{ opacity: 1 }}
              exit={{ opacity: 0 }}
              transition={{ duration: 0.25 }}
            >
              <button
                type="button"
                aria-label={t.close}
                onClick={(e) => {
                  e.stopPropagation();
                  close();
                }}
                className="absolute top-4 right-4 z-10 rounded-full bg-white/10 p-2 text-white transition-colors hover:bg-white/20"
              >
                <svg className="size-5.5" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" aria-hidden="true">
                  <path d="M18 6 6 18M6 6l12 12" />
                </svg>
              </button>
            </motion.div>

            <motion.img
              layoutId={layoutId}
              src={src}
              alt={text}
              draggable={false}
              onClick={(e) => e.stopPropagation()}
              onPointerDown={onPointerDown}
              onPointerMove={onPointerMove}
              onPointerUp={onPointerUp}
              onPointerCancel={onPointerUp}
              animate={{ scale: zoom, x: pan.x, y: pan.y }}
              transition={dragging ? { duration: 0 } : MORPH}
              className={cn(
                "relative max-h-full max-w-full touch-none rounded-md object-contain opacity-100! shadow-2xl select-none",
                zoom > MIN_ZOOM ? "cursor-grab" : "cursor-zoom-out",
                dragging && "cursor-grabbing",
              )}
            />

            <div
              className="absolute bottom-4 left-1/2 z-10 flex -translate-x-1/2 items-center gap-1 rounded-full bg-black/60 p-1 text-white shadow-lg backdrop-blur-sm"
              onClick={(e) => e.stopPropagation()}
            >
              <button type="button" aria-label={t.zoomOut} disabled={zoom <= MIN_ZOOM} onClick={() => changeZoom(-STEP)} className={iconButton}>
                −
              </button>
              <span className="min-w-12 text-center font-mono text-[11px] tabular-nums" aria-live="polite">
                {Math.round(zoom * 100)}%
              </span>
              <button type="button" aria-label={t.zoomIn} disabled={zoom >= MAX_ZOOM} onClick={() => changeZoom(STEP)} className={iconButton}>
                +
              </button>
              <button
                type="button"
                aria-label={t.resetZoom}
                disabled={zoom === MIN_ZOOM && pan.x === 0 && pan.y === 0}
                onClick={reset}
                className="ml-1 rounded-full px-3 py-2 font-mono text-[10px] tracking-wide transition-colors hover:bg-white/15 disabled:cursor-not-allowed disabled:opacity-35"
              >
                {t.reset}
              </button>
            </div>
          </motion.div>
        )}
      </AnimatePresence>
    </>
  );
}
