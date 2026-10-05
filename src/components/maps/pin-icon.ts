import L from "leaflet";

export function createPinIcon(color = "#FFCC00") {
  return L.divIcon({
    html: `
      <svg width="30" height="40" viewBox="0 0 30 40" xmlns="http://www.w3.org/2000/svg">
        <path d="M15 0C6.7 0 0 6.7 0 15c0 10.5 13 23.7 13.6 24.3a2 2 0 0 0 2.8 0C17 38.7 30 25.5 30 15 30 6.7 23.3 0 15 0z"
          fill="${color}" stroke="#3A2E00" stroke-width="1.5"/>
        <circle cx="15" cy="15" r="6" fill="#3A2E00"/>
      </svg>
    `,
    className: "",
    iconSize: [30, 40],
    iconAnchor: [15, 40],
    popupAnchor: [0, -36],
  });
}
