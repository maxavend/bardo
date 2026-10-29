type Sharing = {
  share?: (data: { title: string; url: string }) => Promise<void>
  clipboard?: { writeText: (text: string) => Promise<void> }
}

/** Cancellation is intentional. Missing permissions/APIs offer a manual fallback. */
export async function shareLink(url: string, browser: Sharing): Promise<"shared" | "cancelled" | "copied" | "manual"> {
  if (browser.share) {
    try {
      await browser.share({ title: "Bardo para Mac", url })
      return "shared"
    } catch (error) {
      if (error instanceof Error && error.name === "AbortError") return "cancelled"
    }
  }
  try {
    if (!browser.clipboard) return "manual"
    await browser.clipboard.writeText(url)
    return "copied"
  } catch {
    return "manual"
  }
}
