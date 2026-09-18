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

/**
 * Pulls lat/lng straight out of an already-"long" Google Maps URL — no
 * network needed, just the URL text. Tried in order of how trustworthy the
 * number actually is:
 *   1. `!3d<lat>!4d<lng>` — the exact pinned point Maps embeds for a place.
 *   2. `@<lat>,<lng>,<zoom>z` — where the *camera* was centered, which can
 *      differ from the pin if whoever shared the link had panned around.
 *   3. `?q=<lat>,<lng>` / `?query=<lat>,<lng>` — the plain "search this
 *      point" link shape (also what googleMapsCoordUrl() above generates,
 *      so a link we produced for one factory re-extracts correctly if
 *      pasted somewhere else).
 *   4. `/maps/place/<lat>,<lng>` — a bare-coordinate place path.
 * Returns null for a link that doesn't carry coordinates at all — a plain
 * text-search link, a place name with no `!3d!4d`, or (most commonly) a
 * shortened share link (maps.app.goo.gl/...) that only reveals its
 * coordinates after its redirect is followed — see isShortMapsUrl().
 */
export function extractLatLngFromMapsUrl(url: string): { lat: number; lng: number } | null {
  const patterns = [
    /!3d(-?\d{1,2}(?:\.\d+)?)!4d(-?\d{1,3}(?:\.\d+)?)/,
    /@(-?\d{1,2}(?:\.\d+)?),(-?\d{1,3}(?:\.\d+)?)/,
    /[?&]q=(-?\d{1,2}(?:\.\d+)?),(-?\d{1,3}(?:\.\d+)?)/,
    /[?&]query=(-?\d{1,2}(?:\.\d+)?),(-?\d{1,3}(?:\.\d+)?)/,
    /\/maps\/place\/(-?\d{1,2}(?:\.\d+)?),\+?(-?\d{1,3}(?:\.\d+)?)/,
  ];
  for (const pattern of patterns) {
    const match = url.match(pattern);
    if (!match) continue;
    const lat = Number.parseFloat(match[1]);
    const lng = Number.parseFloat(match[2]);
    if (Number.isFinite(lat) && Number.isFinite(lng) && Math.abs(lat) <= 90 && Math.abs(lng) <= 180) {
      return { lat, lng };
    }
  }
  return null;
}

/**
 * Google's shortened share-link hosts — what "Share > Copy link" on the
 * Maps mobile app actually produces most of the time. These never carry
 * coordinates in the URL itself (they're an opaque id), so getting lat/lng
 * out of one means following its HTTP redirect to the real maps.google.com
 * URL first — see resolveMapsUrlCoordsAction in lib/actions/admin.ts,
 * the only place allowed to do that (it needs a server-side fetch).
 */
export function isShortMapsUrl(url: string): boolean {
  return /^https?:\/\/(maps\.app\.goo\.gl|goo\.gl\/maps|g\.co\/maps)\//i.test(url.trim());
}
