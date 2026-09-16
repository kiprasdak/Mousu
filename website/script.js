"use strict";

// Each visit starts with the full hero, including reloads and restored tabs.
if ("scrollRestoration" in history) history.scrollRestoration = "manual";
const showPageTop = () => window.scrollTo({ top: 0, left: 0, behavior: "instant" });
showPageTop();
window.addEventListener("pageshow", showPageTop);

// Empty header space must not snap a selection to the nearest word.
const siteHeader = document.querySelector(".site-header");
const wordmark = siteHeader?.querySelector(".wordmark");
document.addEventListener("mousedown", (event) => {
  if (event.button !== 0 || !siteHeader || wordmark?.contains(event.target) ||
      event.target.closest("a, button")) return;
  const bounds = siteHeader.getBoundingClientRect();
  if (event.clientY < bounds.top || event.clientY >= bounds.bottom) return;
  getSelection()?.removeAllRanges();
  event.preventDefault();
});

// Escape releases page keyboard focus.
document.addEventListener("keydown", (event) => {
  if (event.key !== "Escape" || event.defaultPrevented) return;
  const focused = document.activeElement;
  if (focused instanceof HTMLElement && focused.matches("a, button, [tabindex]")) {
    focused.blur();
    event.preventDefault();
  }
});

// One small entrance per feature. Content is visible even if JS or observation fails.
const motionPreference = matchMedia("(prefers-reduced-motion: reduce)");
const entranceAnimations = new Set();
let entranceObserver;
if (!motionPreference.matches && "IntersectionObserver" in window && "animate" in Element.prototype) {
  entranceObserver = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      entranceObserver.unobserve(entry.target);
      if (motionPreference.matches) return;
      const animation = entry.target.animate(
        [{ opacity: .88, transform: "translateY(8px)" }, { opacity: 1, transform: "none" }],
        { duration: 420, easing: "cubic-bezier(.2,.7,.2,1)" }
      );
      entranceAnimations.add(animation);
      animation.finished.then(() => entranceAnimations.delete(animation), () => entranceAnimations.delete(animation));
    });
  }, { threshold: .15 });
  document.querySelectorAll(".showcase-detail").forEach((figure) => entranceObserver.observe(figure));
}
motionPreference.addEventListener("change", () => {
  if (!motionPreference.matches) return;
  entranceObserver?.disconnect();
  entranceAnimations.forEach((animation) => animation.cancel());
  entranceAnimations.clear();
});
