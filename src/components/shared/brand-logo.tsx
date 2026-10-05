export function BrandBadge({ className }: { className?: string }) {
  return (
    // eslint-disable-next-line @next/next/no-img-element
    <img src="/images/el-rewad-badge.svg" alt="EL REWAD" className={className} />
  );
}

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
