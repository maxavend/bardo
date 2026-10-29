/** Paths inside the site, so it works at the root or under a GitHub Pages base. */
export function url(path = "") {
  const base = import.meta.env.BASE_URL.replace(/\/$/, "")
  return `${base}/${path}`
}

/** The current release: the one place its version and date live. */
export const release = {
  version: "1.1.1",
  date: "2026-10-27",
  dateLabel: "27 de octubre de 2026",
}

const repo = "https://github.com/maxavend/bardo"

export const links = {
  repo,
  releases: `${repo}/releases`,
  /** The DMG the Release workflow attaches to the tag v<version>. */
  dmg: `${repo}/releases/download/v${release.version}/Bardo-${release.version}.dmg`,
  license: `${repo}/blob/main/LICENSE`,
}

export const requirements = "Mac con Apple silicon y macOS 15 o posterior"

export type Page = "inicio" | "descargar" | "novedades" | "privacidad"
