// Plain <img>, not next/image, on purpose — these are already-vector SVGs
// referenced by URL (not a static import), and next/image's optimizer
// blocks SVGs by default (dangerouslyAllowSVG). Nothing here needs
// resizing/format conversion anyway, so a plain tag avoids that entirely.

/**
 * EL REWAD's badge mark (the red "EL REWAD" pill, no COMPANY/SINCE 1996
 * line) — small and self-contained, so it reads fine on any background.
 * Used in the staff AppShell header next to the role badge.
 */
export function BrandBadge({ className }: { className?: string }) {
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img src="/images/el-rewad-badge.svg" alt="EL REWAD" className={className} />
  );
}

/**
 * The full lockup — badge + "COMPANY" + "SINCE 1996" — with white secondary
 * text, meant for the dark photo hero backgrounds on the homepage and login
 * screen (see HeroBackground). Don't use this over a light/white surface;
 * use BrandBadge there instead.
 */
export function BrandLogoFull({ className }: { className?: string }) {
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img
      src="/images/el-rewad-logo-full.svg"
      alt="EL REWAD — Company, since 1996"
      className={className}
    />
  );
}
