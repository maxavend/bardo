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

/**
 * The first release with Windows installers, or null while there is none. Until then the
 * site offers Windows as coming soon. A preview build can set PUBLIC_WINDOWS_RELEASE.
 */
export const windowsRelease: string | null = import.meta.env.PUBLIC_WINDOWS_RELEASE || null

const repo = "https://github.com/maxavend/bardo"

export const links = {
  repo,
  releases: `${repo}/releases`,
  /** The DMG the Release workflow attaches to the tag v<version>. */
  dmg: `${repo}/releases/download/v${release.version}/Bardo-${release.version}.dmg`,
  license: `${repo}/blob/main/LICENSE`,
  /** The installers the Release workflow attaches next to the DMG. */
  windows: windowsRelease
    ? {
        x64: `${repo}/releases/download/v${windowsRelease}/Bardo-${windowsRelease}-Setup-x64.exe`,
        arm64: `${repo}/releases/download/v${windowsRelease}/Bardo-${windowsRelease}-Setup-arm64.exe`,
      }
    : null,
}

export const requirements = "Mac con Apple silicon y macOS 15 o posterior"

export const windowsRequirements = "Windows 11, en un PC x64 o ARM"

/** What a visitor's computer is, as far as the browser tells. */
export type Platform = "mac" | "windows-x64" | "windows-arm64" | "other"

export type Page = "inicio" | "descargar" | "novedades" | "privacidad"
