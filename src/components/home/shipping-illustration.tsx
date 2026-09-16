/**
 * Purely decorative cartoon scene for the homepage background — a flat,
 * hand-drawn-style delivery truck with a waving driver, on a little road
 * with clouds/hills behind it. Not a real photo/render, matches the app's
 * DHL-yellow brand color for the truck. `aria-hidden` since it carries no
 * information, just mood — screen readers should skip straight to the
 * actual heading/cards.
 */
export function ShippingIllustration({ className = "" }: { className?: string }) {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 1200 400"
      preserveAspectRatio="xMidYMax slice"
      className={className}
    >
      {/* sky glow behind the sun — a slow pulse. transformBox/transformOrigin
          so the CSS scale grows from the circle's own center, not the SVG
          viewport's origin. */}
      <circle
        cx="1040"
        cy="90"
        r="140"
        fill="#FFE9A8"
        opacity="0.35"
        className="animate-sun-glow"
        style={{ transformBox: "fill-box", transformOrigin: "center" }}
      />
      <circle cx="1040" cy="90" r="46" fill="#FFDD66" />

      {/* clouds — each sits in its own non-animated <g transform="translate(...)">
          (its base position) wrapped in an outer <g> that carries only the
          CSS drift animation, so the two transforms never fight each other. */}
      <g fill="#FFFFFF" opacity="0.9">
        <g className="animate-cloud-drift">
          <g transform="translate(120,70)">
            <ellipse cx="0" cy="20" rx="42" ry="22" />
            <ellipse cx="34" cy="8" rx="30" ry="20" />
            <ellipse cx="-34" cy="10" rx="26" ry="17" />
          </g>
        </g>
        <g className="animate-cloud-drift" style={{ animationDelay: "-3s", animationDuration: "11s" }} opacity="0.8">
          <g transform="translate(430,40)">
            <ellipse cx="0" cy="16" rx="34" ry="17" />
            <ellipse cx="26" cy="6" rx="22" ry="15" />
            <ellipse cx="-24" cy="8" rx="20" ry="13" />
          </g>
        </g>
        <g className="animate-cloud-drift" style={{ animationDelay: "-6s", animationDuration: "13s" }} opacity="0.7">
          <g transform="translate(820,55)">
            <ellipse cx="0" cy="16" rx="30" ry="15" />
            <ellipse cx="22" cy="6" rx="18" ry="13" />
          </g>
        </g>
      </g>

      {/* rolling hills, far behind the road */}
      <ellipse cx="150" cy="330" rx="260" ry="90" fill="#FFE58A" opacity="0.35" />
      <ellipse cx="620" cy="345" rx="320" ry="95" fill="#FFDD66" opacity="0.3" />
      <ellipse cx="1080" cy="335" rx="240" ry="85" fill="#FFE58A" opacity="0.3" />

      {/* road */}
      <rect x="0" y="308" width="1200" height="92" fill="#3A3F4B" />
      <rect x="0" y="308" width="1200" height="6" fill="#4A5063" />
      {/* dashes scroll leftward on a loop exactly one dash-spacing (110px)
          wide, so the pattern seams perfectly — the svg root clips anything
          that drifts past the viewBox, same as it always has. */}
      <g className="animate-road-scroll">
        {Array.from({ length: 12 }).map((_, i) => (
          <rect key={i} x={1150 - i * 110} y="350" width="46" height="10" rx="5" fill="#F4F4F4" opacity="0.85" />
        ))}
      </g>

      {/* motion lines trailing behind the truck (it's heading left) — reuse
          the shimmer pulse so they read as flickering speed lines */}
      <g stroke="#C7CBD1" strokeWidth="6" strokeLinecap="round" opacity="0.8" className="animate-shimmer">
        <line x1="915" y1="230" x2="975" y2="230" />
        <line x1="930" y1="255" x2="1010" y2="255" />
        <line x1="915" y1="280" x2="965" y2="280" />
      </g>

      {/* a couple of parcels waiting on the roadside, gently bobbing */}
      <g className="animate-float">
        <g transform="translate(1080,255)">
          <rect x="-28" y="-28" width="56" height="56" rx="6" fill="#D9B27C" stroke="#8A6A3E" strokeWidth="3" />
          <line x1="-28" y1="0" x2="28" y2="0" stroke="#8A6A3E" strokeWidth="4" />
          <line x1="0" y1="-28" x2="0" y2="28" stroke="#8A6A3E" strokeWidth="4" />
        </g>
      </g>
      <g className="animate-float" style={{ animationDelay: "-1.5s" }}>
        <g transform="translate(1030,272) scale(0.7)">
          <rect x="-28" y="-28" width="56" height="56" rx="6" fill="#EFC98F" stroke="#8A6A3E" strokeWidth="3" />
          <line x1="-28" y1="0" x2="28" y2="0" stroke="#8A6A3E" strokeWidth="4" />
          <line x1="0" y1="-28" x2="0" y2="28" stroke="#8A6A3E" strokeWidth="4" />
        </g>
      </g>

      {/* ===== truck (heading left) — no attribute transform of its own, so
          the bounce animation can go straight on this outer <g> ===== */}
      <g className="animate-truck-bounce">
        {/* shadow under the truck */}
        <ellipse cx="690" cy="313" rx="230" ry="14" fill="#20242C" opacity="0.18" />

        {/* cargo box */}
        <rect x="640" y="140" width="230" height="140" rx="14" fill="#FFCC00" stroke="#3A2E00" strokeWidth="5" />
        <rect x="640" y="140" width="230" height="34" rx="14" fill="#FFE066" />
        {/* side stripe */}
        <rect x="655" y="228" width="200" height="16" rx="8" fill="#E23B3B" />
        {/* back doors */}
        <line x1="862" y1="150" x2="862" y2="270" stroke="#3A2E00" strokeWidth="4" opacity="0.5" />

        {/* cab */}
        <path
          d="M 560 280 L 560 205 Q 560 186 580 186 L 618 186 Q 634 186 642 200 L 652 220 L 652 280 Z"
          fill="#FFCC00"
          stroke="#3A2E00"
          strokeWidth="5"
        />
        {/* windshield */}
        <path d="M 588 200 L 617 200 Q 626 200 631 210 L 636 222 L 588 222 Z" fill="#BEE7FA" stroke="#3A2E00" strokeWidth="3" />
        {/* side mirror */}
        <rect x="548" y="208" width="14" height="10" rx="3" fill="#3A2E00" />

        {/* driver: head + cap, visible through the window, arm waving out */}
        <circle cx="605" cy="238" r="17" fill="#F2C099" />
        <path d="M 588 232 Q 605 214 623 231 L 620 233 Q 605 222 591 234 Z" fill="#2B3A55" />
        {/* waving arm out the window */}
        <path d="M 621 248 Q 636 236 634 218" stroke="#F2C099" strokeWidth="10" strokeLinecap="round" fill="none" />
        <circle cx="634" cy="215" r="7" fill="#F2C099" />

        {/* bumper + headlight */}
        <rect x="552" y="270" width="16" height="14" rx="4" fill="#3A2E00" />
        <circle cx="558" cy="238" r="7" fill="#FFF3C4" stroke="#3A2E00" strokeWidth="2" />

        {/* wheels */}
        <g>
          <circle cx="618" cy="292" r="30" fill="#20242C" />
          <circle cx="618" cy="292" r="13" fill="#9AA0AC" />
          <circle cx="800" cy="292" r="30" fill="#20242C" />
          <circle cx="800" cy="292" r="13" fill="#9AA0AC" />
        </g>
      </g>
    </svg>
  );
}
