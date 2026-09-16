"use client";

import { useMemo } from "react";
import { MapContainer, TileLayer, Marker, Popup } from "react-leaflet";
import { createPinIcon } from "./pin-icon";

const DEFAULT_CENTER: [number, number] = [30.0444, 31.2357];

export interface FactoryPin {
  id: string;
  full_name: string;
  address: string | null;
  lat: number;
  lng: number;
}

/**
 * One map, every factory account that has a pin set — a quick "where are
 * our factories" overview for Team management. Factories without
 * coordinates yet just don't show up here (nothing to plot); the table
 * below this map is still the way to set one.
 */
export function FactoriesOverviewMap({ factories }: { factories: FactoryPin[] }) {
  const icon = useMemo(() => createPinIcon(), []);
  const center: [number, number] =
    factories.length > 0 ? [factories[0].lat, factories[0].lng] : DEFAULT_CENTER;

  return (
    <div className="overflow-hidden rounded-lg border">
      <MapContainer center={center} zoom={factories.length > 0 ? 7 : 6} style={{ height: 280, width: "100%" }} scrollWheelZoom={false}>
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
          url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
        />
        {factories.map((f) => (
          <Marker key={f.id} position={[f.lat, f.lng]} icon={icon}>
            <Popup>
              <p className="font-medium">{f.full_name}</p>
              {f.address && <p className="text-xs text-muted-foreground">{f.address}</p>}
            </Popup>
          </Marker>
        ))}
      </MapContainer>
    </div>
  );
}
