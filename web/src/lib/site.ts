/** Paths inside the site, so it works at the root or under a GitHub Pages base. */
export function url(path = "") {
  const base = import.meta.env.BASE_URL.replace(/\/$/, "")
  return `${base}/${path}`
}

export const links = {
  download: "https://github.com/maxavend/bardo/releases/latest",
  releases: "https://github.com/maxavend/bardo/releases",
  repo: "https://github.com/maxavend/bardo",
}

export type Page = "inicio" | "descargar" | "novedades" | "privacidad"
