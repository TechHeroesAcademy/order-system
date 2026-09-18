import { describe, expect, it } from "vitest";
import {
  mapsUrlFor,
  googleMapsCoordUrl,
  googleMapsSearchUrl,
  extractLatLngFromMapsUrl,
  isShortMapsUrl,
} from "@/lib/domain/maps";

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

describe("extractLatLngFromMapsUrl", () => {
  it("prefers the !3d!4d pin over the @ camera position when both are present", () => {
    const url =
      "https://www.google.com/maps/place/Some+Place/@30.0444196,31.2357116,17z/data=!3m1!4b1!4m6!3m5!1s0x0:0x0!8m2!3d30.0459196!4d31.2367116";
    expect(extractLatLngFromMapsUrl(url)).toEqual({ lat: 30.0459196, lng: 31.2367116 });
  });

  it("falls back to the @lat,lng camera position when there's no !3d!4d pin", () => {
    const url = "https://www.google.com/maps/place/Cairo/@30.0444,31.2357,11z";
    expect(extractLatLngFromMapsUrl(url)).toEqual({ lat: 30.0444, lng: 31.2357 });
  });

  it("reads a plain ?q=lat,lng link", () => {
    expect(extractLatLngFromMapsUrl("https://www.google.com/maps?q=30.0444196,31.2357116")).toEqual({
      lat: 30.0444196,
      lng: 31.2357116,
    });
  });

  it("reads its own googleMapsCoordUrl() output back out (round-trips)", () => {
    const url = googleMapsCoordUrl(30.05, 31.3);
    expect(extractLatLngFromMapsUrl(url)).toEqual({ lat: 30.05, lng: 31.3 });
  });

  it("reads a bare /maps/place/lat,lng path", () => {
    expect(extractLatLngFromMapsUrl("https://maps.google.com/maps/place/30.0444196,31.2357116")).toEqual({
      lat: 30.0444196,
      lng: 31.2357116,
    });
  });

  it("returns null for a place link with no coordinates in it", () => {
    expect(extractLatLngFromMapsUrl("https://www.google.com/maps/place/Some+Factory+No+Coords/")).toBeNull();
  });

  it("returns null for a shortened share link (no coordinates embedded — needs redirect resolution)", () => {
    expect(extractLatLngFromMapsUrl("https://maps.app.goo.gl/9RokFHPCVE5gBRHDA")).toBeNull();
  });

  it("returns null for plain text or a non-Maps URL", () => {
    expect(extractLatLngFromMapsUrl("المنطقة الصناعية، مدينة نصر")).toBeNull();
    expect(extractLatLngFromMapsUrl("https://example.com/")).toBeNull();
  });
});

describe("isShortMapsUrl", () => {
  it("recognizes Google's shortened share-link hosts", () => {
    expect(isShortMapsUrl("https://maps.app.goo.gl/9RokFHPCVE5gBRHDA")).toBe(true);
    expect(isShortMapsUrl("https://goo.gl/maps/abc123")).toBe(true);
    expect(isShortMapsUrl("https://g.co/maps/abc123")).toBe(true);
  });

  it("does not flag an already-long maps.google.com link as short", () => {
    expect(isShortMapsUrl("https://www.google.com/maps/place/Cairo/@30.0444,31.2357,11z")).toBe(false);
  });

  it("does not flag an unrelated URL as short", () => {
    expect(isShortMapsUrl("https://example.com/")).toBe(false);
  });
});
