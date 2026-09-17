import { requireRole } from "@/lib/auth";
import { listRegions } from "@/lib/data/orders";
import { listDriverRegionIds } from "@/lib/data/staff";
import { listPickupPoints, listAllPickupPointRegionIds } from "@/lib/data/pickup-points";
import { mapsUrlFor } from "@/lib/domain/maps";
import { Card, CardContent } from "@/components/ui/card";
import { Badge } from "@/components/ui/badge";
import { EmptyState } from "@/components/shared/empty-state";
import { MapPin, Warehouse } from "lucide-react";

/**
 * Read-only for drivers — where to drop off collected pieces instead of
 * driving to Cairo or Alexandria for every single collection (see migration
 * 0026). A driver's own covered مناطق are listed first ("أقرب لك") so the
 * relevant pickup point is easy to find without scrolling past every other
 * one in the company.
 */
export default async function DriverPickupPointsPage() {
  const profile = await requireRole("driver");

  const [points, regions, myRegionIds, pointRegionsMap] = await Promise.all([
    listPickupPoints(),
    listRegions(),
    listDriverRegionIds(profile.id),
    listAllPickupPointRegionIds(),
  ]);

  const active = points.filter((p) => p.is_active);
  const regionNames = (ids: string[]) =>
    regions.filter((r) => ids.includes(r.id)).map((r) => r.name);

  const nearby = active.filter((p) => (pointRegionsMap[p.id] ?? []).some((id) => myRegionIds.includes(id)));
  const others = active.filter((p) => !nearby.includes(p));

  function PointCard({ point }: { point: (typeof active)[number] }) {
    const url = mapsUrlFor(point);
    const names = regionNames(pointRegionsMap[point.id] ?? []);
    return (
      <Card>
        <CardContent className="space-y-1.5 pt-4">
          <p className="font-semibold">{point.name}</p>
          {point.address && <p className="text-sm text-muted-foreground">{point.address}</p>}
          {names.length > 0 && (
            <div className="flex flex-wrap gap-1">
              {names.map((n) => (
                <Badge key={n} variant="outline">
                  {n}
                </Badge>
              ))}
            </div>
          )}
          {url && (
            <a
              href={url}
              target="_blank"
              rel="noopener noreferrer"
              className="inline-flex items-center gap-1 pt-1 text-sm text-primary hover:underline"
            >
              <MapPin className="size-3.5" />
              فتح في خرائط جوجل
            </a>
          )}
        </CardContent>
      </Card>
    );
  }

  return (
    <div className="space-y-4">
      <h1 className="text-xl font-bold">نقاط التجميع</h1>
      <p className="text-sm text-muted-foreground">
        سلّم الأواني اللي جمعتها في أقرب نقطة تجميع بدل التوجه للمصنع في كل مرة.
      </p>

      {active.length === 0 ? (
        <EmptyState icon={Warehouse} title="لا توجد نقاط تجميع مفعّلة حاليًا" />
      ) : (
        <div className="space-y-4">
          {nearby.length > 0 && (
            <div className="space-y-2">
              <h2 className="text-sm font-semibold text-muted-foreground">الأقرب لمناطقك</h2>
              <div className="stagger-children space-y-2">
                {nearby.map((p) => (
                  <PointCard key={p.id} point={p} />
                ))}
              </div>
            </div>
          )}
          {others.length > 0 && (
            <div className="space-y-2">
              <h2 className="text-sm font-semibold text-muted-foreground">نقاط تجميع أخرى</h2>
              <div className="stagger-children space-y-2">
                {others.map((p) => (
                  <PointCard key={p.id} point={p} />
                ))}
              </div>
            </div>
          )}
        </div>
      )}
    </div>
  );
}
