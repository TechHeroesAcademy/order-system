"use client";

import { useEffect, useMemo, useRef } from "react";
import { MapContainer, TileLayer, Marker, Popup, useMapEvents, useMap } from "react-leaflet";
// Imported here rather than in globals.css so it loads with this component's
// dynamic chunk instead of on every page — see the note in globals.css.
import "leaflet/dist/leaflet.css";
import type { Marker as LeafletMarker } from "leaflet";
import { createPinIcon } from "./pin-icon";

// Cairo — a reasonable default center when nothing is plotted yet (this
// app's regions are all Egyptian, see supabase/migrations/0012).
const DEFAULT_CENTER: [number, number] = [30.0444, 31.2357];
// Red map pins, matching the standard "location marker" look — the
// selected/draggable one stays a contrasting blue so it's unmistakable
// which factory is currently open for editing.
const FACTORY_COLOR = "#DC2626";
const SELECTED_COLOR = "#2563eb";

export interface FactoryPin {
  id: string;
  name: string;
  address: string | null;
  lat: number;
  lng: number;
}

function ClickToPlace({ onPick }: { onPick?: (lat: number, lng: number) => void }) {
  useMapEvents({
    click(e) {
      onPick?.(e.latlng.lat, e.latlng.lng);
    },
  });
  return null;
}

/**
 * MapContainer's `center` prop (below) only applies on first mount —
 * react-leaflet doesn't re-center the view just because it changes later.
 * That's fine for a manual click or drag (already happened inside the
 * visible map), but a pin set from an extracted link (lib/actions/admin.ts
 * resolveMapsUrlCoordsAction) can land anywhere, including well outside
 * whatever's currently in view. This flies the view to the selected pin
 * every time it changes, so "extract the lat/lng and pin on the map"
 * actually shows the pin, not just places it somewhere off-screen.
 */
function PanToPin({ lat, lng }: { lat: number; lng: number }) {
  const map = useMap();
  useEffect(() => {
    map.flyTo([lat, lng], Math.max(map.getZoom(), 14), { duration: 0.8 });
  }, [lat, lng, map]);
  return null;
}

/**
 * The one general factories map (Team management, Factories tab) — every
 * factory with a saved pin, plus a distinct-colored, draggable marker for
 * whichever factory is currently selected in <FactoriesMapPanel>. Clicking
 * any pin selects that factory (onSelectPin — the caller opens its inline
 * edit card); clicking empty map space while a factory is selected
 * places/moves that factory's pin (onPinChange). A factory with no
 * coordinates yet gets one the same way: select it (from its marker if it
 * has one, or from the table if it doesn't), then click its spot here.
 *
 * Loaded via `next/dynamic({ ssr: false })` from its callers — Leaflet
 * touches `window` and can't render on the server.
 */
export function FactoriesMap({
  factories,
  selectedId = null,
  selectedPin = null,
  focusPin = null,
  onSelectPin,
  onPinChange,
}: {
  /** Every factory that already has a saved pin (the selected one is drawn separately, see selectedPin). */
  factories: FactoryPin[];
  selectedId?: string | null;
  /** The selected factory's current (possibly unsaved/not-yet-saved) pin position — drives the draggable highlighted marker. */
  selectedPin?: { lat: number; lng: number } | null;
  /**
   * Set only right after a pin is auto-extracted from a pasted Maps link
   * (see resolveMapsUrlCoordsAction) — pans/zooms the view there once,
   * since that point can land anywhere. Deliberately separate from
   * selectedPin: selecting a factory, clicking the map, or dragging the
   * marker already happen within the visible view, so those don't need —
   * and shouldn't trigger — the view jumping around too.
   */
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
              <p className="font-medium">{f.name}</p>
              {f.address && <p className="text-xs text-muted-foreground">{f.address}</p>}
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
