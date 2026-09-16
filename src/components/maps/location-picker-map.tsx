"use client";

import { useMemo, useRef } from "react";
import { MapContainer, TileLayer, Marker, useMapEvents } from "react-leaflet";
import type { Marker as LeafletMarker } from "leaflet";
import { createPinIcon } from "./pin-icon";

// Cairo — a reasonable default center when a factory has no coordinates yet
// (this app's regions are all Egyptian, see supabase/migrations/0012).
const DEFAULT_CENTER: [number, number] = [30.0444, 31.2357];
const DEFAULT_ZOOM = 12;
const PICKED_ZOOM = 15;

function ClickToPlace({ onPick }: { onPick: (lat: number, lng: number) => void }) {
  useMapEvents({
    click(e) {
      onPick(e.latlng.lat, e.latlng.lng);
    },
  });
  return null;
}

/**
 * Click anywhere on the map (or drag the pin) to set a factory's exact
 * coordinates. Used from the Add/Edit factory dialogs in Team management —
 * imported with `next/dynamic({ ssr: false })` from there, since Leaflet
 * touches `window` and can't render on the server.
 */
export function LocationPickerMap({
  lat,
  lng,
  onChange,
}: {
  lat: number | null;
  lng: number | null;
  onChange: (lat: number, lng: number) => void;
}) {
  const markerRef = useRef<LeafletMarker | null>(null);
  const icon = useMemo(() => createPinIcon(), []);
  const hasPin = lat != null && lng != null;
  const center: [number, number] = hasPin ? [lat, lng] : DEFAULT_CENTER;

  return (
    <div className="overflow-hidden rounded-lg border">
      <MapContainer
        center={center}
        zoom={hasPin ? PICKED_ZOOM : DEFAULT_ZOOM}
        style={{ height: 220, width: "100%" }}
        scrollWheelZoom={false}
      >
        <TileLayer
          attribution='&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>'
          url="https://{s}.tile.openstreetmap.org/{z}/{x}/{y}.png"
        />
        <ClickToPlace onPick={onChange} />
        {hasPin && (
          <Marker
            position={[lat, lng]}
            icon={icon}
            draggable
            ref={markerRef}
            eventHandlers={{
              dragend: () => {
                const marker = markerRef.current;
                if (!marker) return;
                const pos = marker.getLatLng();
                onChange(pos.lat, pos.lng);
              },
            }}
          />
        )}
      </MapContainer>
    </div>
  );
}
