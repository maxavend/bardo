const targets = [...document.querySelectorAll<HTMLElement>("[data-reveal]")]
const motion = window.matchMedia("(prefers-reduced-motion: reduce)")

if (!motion.matches) document.documentElement.classList.add("hero-enter-ready")

if (targets.length && "IntersectionObserver" in window && !motion.matches) {
  const observer = new IntersectionObserver(
    (entries) => {
      for (const entry of entries) {
        if (!entry.isIntersecting) continue
        entry.target.setAttribute("data-revealed", "")
        observer.unobserve(entry.target)
      }
    },
    { threshold: 0.12, rootMargin: "0px 0px -6% 0px" },
  )

  document.documentElement.classList.add("reveal-ready")
  // Let the hidden starting state paint once before observing elements already
  // in the viewport; otherwise their first reveal can be collapsed into one frame.
  requestAnimationFrame(() => {
    requestAnimationFrame(() => targets.forEach((target) => observer.observe(target)))
  })

  motion.addEventListener("change", (event) => {
    if (!event.matches) return
    observer.disconnect()
    document.documentElement.classList.remove("reveal-ready")
    targets.forEach((target) => target.setAttribute("data-revealed", ""))
  }, { once: true })
}
