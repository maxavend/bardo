const imageSlots = [...document.querySelectorAll<HTMLElement>("[data-image-reveal]")]

for (const slot of imageSlots) {
  const image = slot.querySelector("img")
  if (!image) {
    slot.classList.add("is-revealed")
    continue
  }

  const reveal = () => {
    slot.dataset.state = "loaded"
    slot.classList.add("is-revealed")
  }

  if (image.complete) {
    reveal()
    continue
  }

  image.addEventListener("load", reveal, { once: true })
  image.addEventListener("error", reveal, { once: true })
}

document.documentElement.classList.add("image-reveal-ready")
