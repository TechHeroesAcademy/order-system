import type { Region } from "@/types/database";

export function RegionDatalist({ id, regions }: { id: string; regions: Region[] }) {
  return (
    <datalist id={id}>
      {regions.map((r) => (
        <option key={r.id} value={r.name} />
      ))}
    </datalist>
  );
}
