/** Paths inside the site, so it works at the root or under a GitHub Pages base. */
export function url(path = "") {
  const base = import.meta.env.BASE_URL.replace(/\/$/, "")
  return `${base}/${path}`
}

const repo = "https://github.com/maxavend/bardo"

interface GitHubRelease {
  tag_name: string
  published_at: string | null
  draft: boolean
  prerelease: boolean
  assets: { name: string }[]
}

/**
 * The release the site offers when GitHub cannot be reached while building, so a build
 * never fails or links to nothing. Bump it now and then; a normal build reads GitHub.
 */
const fallback = { version: "1.2.0", publishedAt: "2026-10-29T18:03:00Z", windowsVersion: "1.2.0" as string | null }

/** Published releases, newest first, or null when GitHub does not answer. */
async function readReleases(): Promise<GitHubRelease[] | null> {
  const token = import.meta.env.GITHUB_TOKEN
  try {
    const response = await fetch("https://api.github.com/repos/maxavend/bardo/releases?per_page=30", {
      headers: { Accept: "application/vnd.github+json", ...(token ? { Authorization: `Bearer ${token}` } : {}) },
      signal: AbortSignal.timeout(8000),
    })
    if (!response.ok) throw new Error(`GitHub answered ${response.status}`)
    const releases = (await response.json()) as GitHubRelease[]
    return releases.filter(entry => !entry.draft && !entry.prerelease && entry.published_at)
  } catch (error) {
    console.warn(`[site] Could not read the releases (${(error as Error).message}); offering ${fallback.version}.`)
    return null
  }
}

const versionOf = (entry: GitHubRelease) => entry.tag_name.replace(/^v/, "")
const carries = (entry: GitHubRelease, ...names: string[]) => names.every(name => entry.assets.some(asset => asset.name === name))
const installers = (version: string) => [`Bardo-${version}-Setup-x64.exe`, `Bardo-${version}-Setup-arm64.exe`]

const releases = await readReleases()
// The newest release with a DMG, and the newest with both Windows installers: a Mac-only
// fix after a Windows release keeps offering that release's installers.
const macEntry = releases?.find(entry => carries(entry, `Bardo-${versionOf(entry)}.dmg`))
const windowsEntry = releases?.find(entry => carries(entry, ...installers(versionOf(entry))))

const macVersion = macEntry ? versionOf(macEntry) : fallback.version
const publishedAt = new Date(macEntry?.published_at ?? fallback.publishedAt)
const inChile = (options: Intl.DateTimeFormatOptions, locale = "es") =>
  new Intl.DateTimeFormat(locale, { timeZone: "America/Santiago", ...options }).format(publishedAt)

/** The newest Mac release, read from GitHub when the site builds. */
export const release = {
  version: macVersion,
  date: inChile({ year: "numeric", month: "2-digit", day: "2-digit" }, "en-CA"),
  dateLabel: inChile({ day: "numeric", month: "long", year: "numeric" }),
}

/**
 * The newest release with Windows installers, or null while there is none. Until then the
 * site offers Windows as coming soon. A preview build can set PUBLIC_WINDOWS_RELEASE.
 */
export const windowsRelease: string | null =
  import.meta.env.PUBLIC_WINDOWS_RELEASE || (windowsEntry ? versionOf(windowsEntry) : releases ? null : fallback.windowsVersion)

const download = (version: string, name: string) => `${repo}/releases/download/v${version}/${name}`

export const links = {
  repo,
  releases: `${repo}/releases`,
  /** The DMG the Release workflow attaches to the tag v<version>. */
  dmg: download(release.version, `Bardo-${release.version}.dmg`),
  /** The page of the release the DMG belongs to, with its .sha256. */
  macRelease: `${repo}/releases/tag/v${release.version}`,
  license: `${repo}/blob/main/LICENSE`,
  /** The installers the Release workflow attaches next to the DMG. */
  windows: windowsRelease
    ? {
        x64: download(windowsRelease, installers(windowsRelease)[0]),
        arm64: download(windowsRelease, installers(windowsRelease)[1]),
        release: `${repo}/releases/tag/v${windowsRelease}`,
      }
    : null,
}

export const requirements = "Mac con Apple silicon y macOS 15 o posterior"

export const windowsRequirements = "Windows 11, en un PC x64 o ARM"

/** What a visitor's computer is, as far as the browser tells. */
export type Platform = "mac" | "windows-x64" | "windows-arm64" | "other"

export type Page = "inicio" | "descargar" | "novedades" | "privacidad"
