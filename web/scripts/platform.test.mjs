import assert from "node:assert/strict"
import test from "node:test"
import { detectPlatform } from "../src/scripts/platform.ts"

const chromium = (platform, architecture, mobile = false) => ({
  userAgent: "Mozilla/5.0",
  userAgentData: { platform, mobile, async getHighEntropyValues() { return { architecture } } },
})

test("Edge and Chrome tell ARM Windows from x64", async () => {
  assert.equal(await detectPlatform(chromium("Windows", "arm")), "windows-arm64")
  assert.equal(await detectPlatform(chromium("Windows", "x86")), "windows-x64")
  assert.equal(await detectPlatform(chromium("macOS", "arm")), "mac")
})

test("a Windows browser that hides its architecture gets x64", async () => {
  const nav = chromium("Windows", undefined)
  nav.userAgentData.getHighEntropyValues = async () => { throw new Error("Not allowed") }
  assert.equal(await detectPlatform(nav), "windows-x64")
})

test("Firefox and Safari are read from the user agent", async () => {
  assert.equal(await detectPlatform({ userAgent: "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:140.0) Gecko/20100101 Firefox/140.0" }), "windows-x64")
  assert.equal(await detectPlatform({ userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 Safari/605.1.15", maxTouchPoints: 0 }), "mac")
})

test("phones and iPads are not computers Bardo runs on", async () => {
  assert.equal(await detectPlatform({ userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Safari/605.1.15", maxTouchPoints: 5 }), "other")
  assert.equal(await detectPlatform({ userAgent: "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)" }), "other")
  assert.equal(await detectPlatform(chromium("Android", "arm", true)), "other")
  assert.equal(await detectPlatform(chromium("Linux", "x86")), "other")
})
