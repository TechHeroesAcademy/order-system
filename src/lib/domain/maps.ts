/**
 * Google Maps link helpers, shared by every place that shows a customer's
 * or a factory's address to staff (order detail views, the driver's order
 * page, the factory picker note). Centralized so the URL pattern — and the
 * "prefer precise coordinates when we have them" upgrade — only needs to
 * live in one place.
 */

/** A Maps search for a free-text address — works anywhere, but only as precise as the text itself. */
export function googleMapsSearchUrl(address: string): string {
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(address)}`;
}

/** A Maps link pinned to exact coordinates — precise, used whenever we have lat/lng. */
export function googleMapsCoordUrl(lat: number, lng: number): string {
  return `https://www.google.com/maps/search/?api=1&query=${lat},${lng}`;
}

/**
 * Best available Maps link for a location that may have a directly-pasted
 * Google Maps link, precise coordinates (from the Leaflet picker), and/or
 * just a free-text address — prefers the pasted link (it's the most
 * intentional/precise thing staff can give us — e.g. a "share link" a
 * customer sent on WhatsApp/Messenger), then coordinates, then falls back to
 * a text search, and is null only when there's nothing to link to at all.
 */
export function mapsUrlFor(location: {
  maps_url?: string | null;
  address?: string | null;
  lat?: number | null;
  lng?: number | null;
}): string | null {
  if (location.maps_url) {
    return location.maps_url;
  }
  if (location.lat != null && location.lng != null) {
    return googleMapsCoordUrl(location.lat, location.lng);
  }
  if (location.address) {
    return googleMapsSearchUrl(location.address);
  }
  return null;
}
