import { describe, expect, it } from "vitest";
import { mapsUrlFor, googleMapsCoordUrl, googleMapsSearchUrl } from "@/lib/domain/maps";

describe("mapsUrlFor", () => {
  const pastedLink = "https://www.google.com/maps/place/Nasr+City,+Cairo/@30.0566281,31.3198079,3052m";

  it("prefers a directly-pasted Google Maps link over everything else", () => {
    const url = mapsUrlFor({ maps_url: pastedLink, address: "مدينة نصر", lat: 30.05, lng: 31.3 });
    expect(url).toBe(pastedLink);
  });

  it("falls back to precise coordinates when there's no pasted link", () => {
    const url = mapsUrlFor({ maps_url: null, address: "مدينة نصر", lat: 30.05, lng: 31.3 });
    expect(url).toBe(googleMapsCoordUrl(30.05, 31.3));
  });

  it("falls back to a text-address search when there's no link or coordinates", () => {
    const url = mapsUrlFor({ maps_url: null, address: "مدينة نصر", lat: null, lng: null });
    expect(url).toBe(googleMapsSearchUrl("مدينة نصر"));
  });

  it("returns null when there is nothing to link to", () => {
    expect(mapsUrlFor({ maps_url: null, address: null, lat: null, lng: null })).toBeNull();
    expect(mapsUrlFor({})).toBeNull();
  });

  it("ignores an empty-string pasted link (falls through to the next option)", () => {
    const url = mapsUrlFor({ maps_url: "", address: "مدينة نصر" });
    expect(url).toBe(googleMapsSearchUrl("مدينة نصر"));
  });
});
