import assert from "node:assert/strict"
import test from "node:test"
import { shareLink } from "../src/components/site/share-link.ts"

const url = "https://example.com/descargar/"

test("sharing succeeds without altering the clipboard", async () => {
  assert.equal(await shareLink(url, {
    async share(data) { assert.deepEqual(data, { title: "Bardo para Mac", url }) },
    clipboard: { async writeText() { assert.fail("Unexpected clipboard write") } },
  }), "shared")
})

test("cancelling the share sheet does not copy the link", async () => {
  assert.equal(await shareLink(url, {
    async share() { throw new DOMException("Cancelled", "AbortError") },
    clipboard: { async writeText() { assert.fail("Cancellation must not copy") } },
  }), "cancelled")
})

test("unavailable sharing falls back to copying", async () => {
  assert.equal(await shareLink(url, {
    async share() { throw new DOMException("Unavailable", "NotAllowedError") },
    clipboard: { async writeText(text) { assert.equal(text, url) } },
  }), "copied")
})

test("missing native share still copies", async () => {
  assert.equal(await shareLink(url, {
    clipboard: { async writeText(text) { assert.equal(text, url) } },
  }), "copied")
})

test("clipboard denial offers a manual link", async () => {
  assert.equal(await shareLink(url, {
    clipboard: { async writeText() { throw new DOMException("Denied", "NotAllowedError") } },
  }), "manual")
})

test("browsers without either API offer a manual link", async () => {
  assert.equal(await shareLink(url, {}), "manual")
})
