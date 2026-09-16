import Image from "next/image";

/**
 * Full-bleed photographic hero background — replaces the old hand-drawn
 * cartoon truck illustration with a real, professional warehouse/logistics
 * photo (open-licensed, free for commercial use, no attribution required:
 * https://www.pexels.com/license/ — photo by William Buzeichuk,
 * https://www.pexels.com/photo/expansive-warehouse-aisle-filled-with-products-29454379/).
 * A dark gradient sits over the photo so white text stays legible against
 * whatever part of the image is behind it, and a thin brand-yellow bar
 * along the bottom edge ties it back to the app's own color, the same way
 * a real logistics company's marketing pages pair photography with a
 * confident brand-color accent instead of illustration.
 */
export function HeroBackground({ className = "" }: { className?: string }) {
  return (
    <div aria-hidden="true" className={`pointer-events-none absolute inset-0 overflow-hidden ${className}`}>
      <Image
        src="https://images.pexels.com/photos/29454379/pexels-photo-29454379.jpeg?auto=compress&cs=tinysrgb&w=1920"
        alt=""
        fill
        priority
        sizes="100vw"
        className="object-cover"
      />
      <div className="absolute inset-0 bg-gradient-to-t from-black/85 via-black/55 to-black/25" />
      <div className="absolute inset-x-0 bottom-0 h-1.5 bg-primary" />
    </div>
  );
}
