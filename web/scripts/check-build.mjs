import assert from "node:assert/strict"
import { createHash } from "node:crypto"
import { readFileSync, existsSync, statSync } from "node:fs"
import { resolve } from "node:path"

const root = resolve("dist")
const routes = ["", "descargar", "privacidad", "novedades"]

for (const route of routes) {
  const file = resolve(root, route, "index.html")
  const html = readFileSync(file, "utf8")
  const csp = html.match(/<meta http-equiv="content-security-policy" content="([^"]+)"/)?.[1]
  assert.ok(csp, `${route || "/"}: missing CSP`)
  for (const directive of ["default-src 'self'", "object-src 'none'", "base-uri 'none'", "script-src-attr 'none'"]) {
    assert.ok(csp.includes(directive), `Missing ${directive}`)
  }
  const scriptPolicy = csp.match(/(?:^|;)\s*script-src-elem ([^;]+)/)?.[1]
  const stylePolicy = csp.match(/(?:^|;)\s*style-src-elem ([^;]+)/)?.[1]
  assert.ok(scriptPolicy && !/'unsafe-inline'|'unsafe-eval'/.test(scriptPolicy), "Unsafe script policy")
  assert.ok(stylePolicy && !stylePolicy.includes("'unsafe-inline'"), "Unsafe style element policy")

  let inlineBytes = 0
  for (const [, tag, attributes, body] of html.matchAll(/<(script|style)\b([^>]*)>([\s\S]*?)<\/\1>/g)) {
    if (/\bsrc=/.test(attributes) || (tag === "script" && /type="application\//.test(attributes))) continue
    const hash = `sha256-${createHash("sha256").update(body).digest("base64")}`
    assert.ok((tag === "script" ? scriptPolicy : stylePolicy).includes(`'${hash}'`), `${route}: CSP blocks an inline ${tag}`)
    if (tag === "script") inlineBytes += Buffer.byteLength(body)
  }

  const markup = html.replace(/<(script|style)\b[^>]*>[\s\S]*?<\/\1>/g, "")
  assert.ok(!/<[^>]+\son\w+=/i.test(markup), "Inline event handler found")
  for (const [, reference] of html.matchAll(/\b(?:src|href)="([^"#]+)"/g)) {
    if (/^(?:https?:|data:|mailto:)/.test(reference)) continue
    const pathname = decodeURIComponent(reference.split(/[?#]/)[0])
    const asset = pathname.startsWith("/") ? resolve(root, `.${pathname}`) : resolve(file, "..", pathname)
    assert.ok(asset.startsWith(root), "Asset escaped dist")
    assert.ok(existsSync(asset), `${route}: missing ${reference}`)
  }
  if (route) {
    assert.ok(!html.includes("<astro-island"), `${route}: secondary page should not hydrate React`)
    assert.ok(inlineBytes < 8192, `${route}: unnecessary JavaScript grew beyond 8 KiB`)
  } else {
    assert.equal((html.match(/<astro-island\b/g) || []).length, 1, "Only the hero demo should hydrate")
  }
  console.log(`${route || "/"}: CSP hashes, local assets and hydration budget OK (${statSync(file).size} HTML bytes)`)
}

const headers = readFileSync(resolve(root, "_headers"), "utf8")
assert.ok(headers.includes("frame-ancestors 'none'"))
assert.ok(headers.includes("max-age=31536000, immutable"))
