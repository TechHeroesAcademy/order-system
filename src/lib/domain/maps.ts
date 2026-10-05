export function googleMapsSearchUrl(address: string): string {
  return `https://www.google.com/maps/search/?api=1&query=${encodeURIComponent(address)}`;
}

export function googleMapsCoordUrl(lat: number, lng: number): string {
  return `https://www.google.com/maps/search/?api=1&query=${lat},${lng}`;
}

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

export function isShortMapsUrl(url: string): boolean {
  return /^https?:\/\/(maps\.app\.goo\.gl|goo\.gl\/maps|g\.co\/maps)\//i.test(url.trim());
}
