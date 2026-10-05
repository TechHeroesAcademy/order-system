import { describe, it, expect } from "vitest";
import { extractLatLngFromMapsUrl } from "../maps";

const REAL =
  "https://www.google.com/maps/place/Misr+October+Industrial+Co.+-+MOIC/@29.9369844,30.9186728,764m/data=!3m2!1e3!4b1!4m6!3m5!1s0x145855c32380fb4f:0xf9e7e3cefa59edf7!8m2!3d29.9369798!4d30.9212477!16s%2Fg%2F11g6qrcb34?entry=ttu&g_ep=EgoyMDI2MDkyOC4wIKXMDSoASAFQAw%3D%3D";

describe("extractLatLngFromMapsUrl", () => {
  it("takes the place's own coordinates, not the camera centre", () => {
    const r = extractLatLngFromMapsUrl(REAL);
    expect(r).not.toBeNull();
    expect(r!.lat).toBeCloseTo(29.9369798, 6);
    expect(r!.lng).toBeCloseTo(30.9212477, 6);
    expect(r!.lng).not.toBeCloseTo(30.9186728, 6);
  });

  it("the two pairs really are far enough apart for the preference to matter", () => {
    const place = extractLatLngFromMapsUrl(REAL)!;
    const view = extractLatLngFromMapsUrl(REAL.replace(/!3d[\d.]+!4d[\d.]+/, ""))!;
    const metres = Math.hypot(
      (place.lat - view.lat) * 111_320,
      (place.lng - view.lng) * 111_320 * Math.cos((place.lat * Math.PI) / 180),
    );
    expect(metres).toBeGreaterThan(100);
  });

  it("falls back to the camera centre when there is no place attached", () => {
    expect(extractLatLngFromMapsUrl("https://www.google.com/maps/@30.0444,31.2357,15z")).toEqual({
      lat: 30.0444,
      lng: 31.2357,
    });
  });

  it("reads the older ?q= share format", () => {
    expect(extractLatLngFromMapsUrl("https://maps.google.com/?q=29.98,31.13")).toEqual({
      lat: 29.98,
      lng: 31.13,
    });
  });

  it("returns null for a short share link, which carries no coordinates at all", () => {
    expect(extractLatLngFromMapsUrl("https://maps.app.goo.gl/PZ2h1nP7b8qLqKqW9")).toBeNull();
  });

  it("returns null for something that is not a map link", () => {
    expect(extractLatLngFromMapsUrl("شبرا، القاهرة")).toBeNull();
  });
});
