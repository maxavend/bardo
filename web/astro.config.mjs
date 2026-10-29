// @ts-check

import tailwindcss from "@tailwindcss/vite"
import { defineConfig } from "astro/config"
import react from "@astrojs/react"

// https://astro.build/config
export default defineConfig({
  site: "https://bardoformac.maxavend.com",
  vite: {
    plugins: [tailwindcss()],
  },
  integrations: [react()],
  markdown: { syntaxHighlight: false },
  security: {
    csp: {
      directives: [
        "default-src 'self'",
        "img-src 'self' data:",
        "font-src 'self'",
        "connect-src 'self'",
        "object-src 'none'",
        "base-uri 'none'",
        "form-action 'none'",
        "frame-src 'none'",
        "media-src 'none'",
        "worker-src 'none'",
      ],
      scriptDirective: {
        resources: [
          { resource: "'self'", kind: "element" },
          { resource: "'none'", kind: "attribute" },
        ],
      },
      // Astro hashes its scripts/styles. Only style attributes need an exception
      // for the transcript's per-word timing and masks; scripts stay hash-based.
      styleDirective: {
        resources: [
          { resource: "'self'", kind: "element" },
          { resource: "'unsafe-inline'", kind: "attribute" },
        ],
      },
    },
  },
})
