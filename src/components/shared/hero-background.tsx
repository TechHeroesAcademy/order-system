import { CookingPot, Soup } from "lucide-react";

/**
 * A drifting cooking pot/bowl, positioned by its vertical lane and driven
 * by the shared `pot-drift` keyframe (globals.css) — each instance gets its
 * own size/duration/negative-delay/opacity/blur so the set reads as loose
 * depth-of-field parallax (small, dim, slow, blurred = far away; large,
 * bright, quick, sharp = close) rather than one row of identical icons
 * marching in lockstep. `animate-shimmer` (an existing token, reused as-is)
 * doubles as a slow gleam — a freshly-recoated pot catching the light —
 * staggered independently of the drift so they don't all glint together.
 */
function DriftingPot({
  Icon,
  top,
  size,
  duration,
  delay,
  shimmerDelay,
  opacity,
  blurPx,
  tone = "white",
}: {
  Icon: typeof CookingPot;
  top: string;
  size: number;
  duration: string;
  delay: string;
  shimmerDelay: string;
  opacity: number;
  blurPx?: number;
  tone?: "white" | "primary";
}) {
  return (
    <div
      className="animate-pot-drift absolute right-0"
      style={{ top, animationDuration: duration, animationDelay: delay }}
    >
      <Icon
        className={`animate-shimmer ${tone === "primary" ? "text-primary" : "text-white"}`}
        style={{
          width: size,
          height: size,
          opacity,
          filter: blurPx ? `blur(${blurPx}px)` : undefined,
          animationDelay: shimmerDelay,
        }}
        strokeWidth={1.5}
      />
    </div>
  );
}

/** A soft, blurred wisp that rises and fades in place — ambient stove-top warmth, not tied to any one pot's position. */
function SteamWisp({ left, top, delay }: { left: string; top: string; delay: string }) {
  return (
    <div
      className="animate-steam-rise absolute h-10 w-6 rounded-full bg-white/40 blur-md"
      style={{ left, top, animationDelay: delay }}
    />
  );
}

const BACK_POTS: Array<Omit<Parameters<typeof DriftingPot>[0], "shimmerDelay">> = [
  { Icon: CookingPot, top: "8%", size: 38, duration: "36s", delay: "-6s", opacity: 0.16, blurPx: 1.5 },
  { Icon: Soup, top: "24%", size: 32, duration: "44s", delay: "-21s", opacity: 0.13, blurPx: 1.5 },
  { Icon: CookingPot, top: "60%", size: 44, duration: "32s", delay: "-27s", opacity: 0.15, blurPx: 1.5 },
  { Icon: CookingPot, top: "78%", size: 34, duration: "40s", delay: "-11s", opacity: 0.14, blurPx: 1.5 },
  { Icon: Soup, top: "46%", size: 28, duration: "38s", delay: "-33s", opacity: 0.12, blurPx: 1.5 },
];

const FRONT_POTS: Array<Omit<Parameters<typeof DriftingPot>[0], "shimmerDelay">> = [
  { Icon: CookingPot, top: "14%", size: 92, duration: "20s", delay: "-3s", opacity: 0.5, tone: "white" },
  { Icon: CookingPot, top: "66%", size: 108, duration: "24s", delay: "-15s", opacity: 0.4, tone: "primary" },
  { Icon: Soup, top: "42%", size: 76, duration: "22s", delay: "-9s", opacity: 0.4, tone: "white" },
  { Icon: CookingPot, top: "86%", size: 66, duration: "18s", delay: "-13s", opacity: 0.35, tone: "primary" },
];

const STEAM_WISPS = [
  { left: "18%", top: "10%", delay: "-1s" },
  { left: "62%", top: "58%", delay: "-2.4s" },
  { left: "38%", top: "40%", delay: "-3.6s" },
];

/**
 * Full-bleed animated hero background — cooking pots drifting slowly
 * right-to-left (matching the site's own RTL reading direction) across a
 * warm, dark gradient, replacing the old static warehouse/logistics stock
 * photo. Two depth layers (blurred/dim/slow "far" pots behind, sharp/
 * bright/quicker "near" pots in front, sized and staggered independently —
 * see BACK_POTS/FRONT_POTS) plus a few rising steam wisps give it a sense
 * of a working kitchen rather than a static warehouse shelf, and it's the
 * business's actual product on screen rather than a generic logistics
 * photo. Built from lucide's own CookingPot/Soup glyphs (same icon
 * language as the Truck/Factory/ShieldCheck badges further down this exact
 * page) rather than hand-drawn art, so it reads as part of one consistent
 * design system instead of a bolted-on illustration.
 *
 * The dark gradient overlay and bottom accent bar are unchanged from the
 * photo version — still what keeps white foreground text legible and ties
 * the whole thing back to the brand color, respectively. `.hero-drift`
 * (globals.css) freezes every animated layer under prefers-reduced-motion.
 */
export function HeroBackground({ className = "" }: { className?: string }) {
  return (
    <div
      aria-hidden="true"
      className={`hero-drift pointer-events-none absolute inset-0 overflow-hidden bg-gradient-to-br from-[#241a08] via-[#171008] to-[#0c0906] ${className}`}
    >
      {/* Warm stove-light glow behind the pots — the one place brand yellow shows up at full strength here. */}
      <div className="absolute left-1/2 top-1/2 h-[70%] w-[70%] -translate-x-1/2 -translate-y-1/2 rounded-full bg-primary/20 blur-3xl" />

      {BACK_POTS.map((pot, i) => (
        <DriftingPot key={`back-${i}`} {...pot} shimmerDelay={`${(i * 0.7).toFixed(1)}s`} />
      ))}
      {STEAM_WISPS.map((wisp, i) => (
        <SteamWisp key={`steam-${i}`} {...wisp} />
      ))}
      {FRONT_POTS.map((pot, i) => (
        <DriftingPot key={`front-${i}`} {...pot} shimmerDelay={`${(i * 0.9).toFixed(1)}s`} />
      ))}

      <div className="absolute inset-0 bg-gradient-to-t from-black/85 via-black/50 to-black/20" />
      <div className="absolute inset-x-0 bottom-0 h-1.5 bg-primary" />
    </div>
  );
}
