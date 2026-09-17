import type { Region } from "@/types/database";

/**
 * The suggestion list behind a "type your المنطقة" text input (migration
 * 0025) — a plain HTML <datalist>, so it degrades gracefully on the older/
 * low-spec phones this system already has to support (see
 * driver-order-actions.tsx and the delivery/pickup code inputs): typing
 * still works with zero JavaScript, the datalist is just a native browser
 * assist on top. Existing region names are suggested; typing one that
 * doesn't match yet is not blocked — it's created on submit (see
 * find_or_create_region()).
 */
export function RegionDatalist({ id, regions }: { id: string; regions: Region[] }) {
  return (
    <datalist id={id}>
      {regions.map((r) => (
        <option key={r.id} value={r.name} />
      ))}
    </datalist>
  );
}
