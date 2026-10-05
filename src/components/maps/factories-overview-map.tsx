"use client";

import { useEffect, useMemo, useRef } from "react";
import { MapContainer, TileLayer, Marker, Popup, useMapEvents, useMap } from "react-leaflet";
import "leaflet/dist/leaflet.css";
import type { Marker as LeafletMarker } from "leaflet";
import { createPinIcon } from "./pin-icon";

const DEFAULT_CENTER: [number, number] = [30.0444, 31.2357];
const FACTORY_COLOR = "#DC2626";
const SELECTED_COLOR = "#2563eb";

export interface FactoryPin {
  id: string;
  name: string;
  address: string | null;
  lat: number;
  lng: number;
  phone?: string | null;
  maps_url?: string | null;
  is_active?: boolean;
}

function ClickToPlace({ onPick }: { onPick?: (lat: number, lng: number) => void }) {
  useMapEvents({
    click(e) {
      onPick?.(e.latlng.lat, e.latlng.lng);
    },
  });
  return null;
}

function PanToPin({ lat, lng }: { lat: number; lng: number }) {
  const map = useMap();
  useEffect(() => {
    map.flyTo([lat, lng], Math.max(map.getZoom(), 14), { duration: 0.8 });
  }, [lat, lng, map]);
  return null;
}

export function FactoriesMap({
  factories,
  selectedId = null,
  selectedPin = null,
  focusPin = null,
  onSelectPin,
  onPinChange,
}: {
  factories: FactoryPin[];
  selectedId?: string | null;
  selectedPin?: { lat: number; lng: number } | null;
  focusPin?: { lat: number; lng: number } | null;
  onSelectPin?: (id: string) => void;
  onPinChange?: (lat: number, lng: number) => void;
}) {
  const defaultIcon = useMemo(() => createPinIcon(FACTORY_COLOR), []);
  const selectedIcon = useMemo(() => createPinIcon(SELECTED_COLOR), []);
  const markerRef = useRef<LeafletMarker | null>(null);

  const others = factories.filter((f) => f.id !== selectedId);
  const hasAnyPin = others.length > 0 || Boolean(selectedPin);
  const center: [number, number] = selectedPin
    ? [selectedPin.lat, selectedPin.lng]
    : others.length > 0
      ? [others[0].lat, others[0].lng]
      : DEFAULT_CENTER;

  return (
    <div className="overflow-hidden rounded-lg border">
      <MapContainer
        center={center}
        zoom={hasAnyPin ? 7 : 6}
        style={{ height: 360, width: "100%" }}
        scrollWheelZoom={false}
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
          url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
        />
        <ClickToPlace onPick={selectedId ? onPinChange : undefined} />
        {focusPin && <PanToPin lat={focusPin.lat} lng={focusPin.lng} />}
        {others.map((f) => (
          <Marker
            key={f.id}
            position={[f.lat, f.lng]}
            icon={defaultIcon}
            eventHandlers={{ click: () => onSelectPin?.(f.id) }}
          >
            <Popup>
              <div className="min-w-44 space-y-1" dir="rtl">
                <p className="font-medium">{f.name}</p>
                {f.is_active === false && (
                  <p className="text-xs font-medium text-destructive">مصنع موقوف</p>
                )}
                {f.address && <p className="text-xs text-muted-foreground">{f.address}</p>}
                {f.phone && (
                  <p className="text-xs">
                    <a href={`tel:${f.phone}`} className="text-primary underline" dir="ltr">
                      {f.phone}
                    </a>
                  </p>
                )}
                <p className="text-[11px] text-muted-foreground" dir="ltr">
                  {f.lat.toFixed(6)}, {f.lng.toFixed(6)}
                </p>
                <a
                  href={f.maps_url || `https://www.google.com/maps/search/?api=1&query=${f.lat},${f.lng}`}
                  target="_blank"
                  rel="noopener noreferrer"
                  className="inline-block pt-0.5 text-xs font-medium text-primary underline"
                >
                  الاتجاهات على خرائط جوجل ↗
                </a>
              </div>
            </Popup>
          </Marker>
        ))}
        {selectedId && selectedPin && (
          <Marker
            position={[selectedPin.lat, selectedPin.lng]}
            icon={selectedIcon}
            draggable
            ref={markerRef}
            eventHandlers={{
              dragend: () => {
                const marker = markerRef.current;
                if (!marker) return;
                const pos = marker.getLatLng();
                onPinChange?.(pos.lat, pos.lng);
              },
            }}
          />
        )}
      </MapContainer>
    </div>
  );
}
