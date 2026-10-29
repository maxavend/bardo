import type { Platform } from "@/lib/site"

interface HighEntropyValues {
  platform?: string
  architecture?: string
}

interface UserAgentData {
  platform: string
  mobile: boolean
  getHighEntropyValues(hints: string[]): Promise<HighEntropyValues>
}

interface DetectableNavigator {
  userAgent: string
  maxTouchPoints?: number
  userAgentData?: UserAgentData
}

/**
 * The visitor's computer. Edge and Chrome say whether a Windows PC is ARM; other
 * browsers do not, and an x64 build is the safe answer there: Windows on ARM runs it too.
 * Phones and tablets are "other", since Bardo is not for them.
 */
export async function detectPlatform(nav: DetectableNavigator): Promise<Platform> {
  const data = nav.userAgentData
  if (data) {
    if (data.mobile) return "other"
    if (data.platform === "macOS") return "mac"
    if (data.platform === "Windows") {
      try {
        const { architecture } = await data.getHighEntropyValues(["architecture"])
        return architecture === "arm" ? "windows-arm64" : "windows-x64"
      } catch {
        return "windows-x64"
      }
    }
    return "other"
  }
  const agent = nav.userAgent
  if (/iPhone|iPad|Android/i.test(agent)) return "other"
  // iPadOS asks for desktop pages as a Mac; touch gives it away.
  if (/Macintosh/i.test(agent)) return (nav.maxTouchPoints ?? 0) > 1 ? "other" : "mac"
  if (/Windows NT/i.test(agent)) return /ARM64|aarch64/i.test(agent) ? "windows-arm64" : "windows-x64"
  return "other"
}
