import "@testing-library/jest-dom/vitest";

// jsdom implements the scroll *properties* (scrollTop, scrollHeight) but not the
// scrollTo() *method* on elements, so any component that scrolls a container to
// the bottom — the chat thread, notably — throws "scrollTo is not a function"
// the moment it renders under test. That's a gap in the test DOM, not in the
// component, so it's stubbed once here rather than worked around per test.
if (typeof Element !== "undefined" && !Element.prototype.scrollTo) {
  Element.prototype.scrollTo = function scrollTo() {};
}
