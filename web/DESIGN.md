---
name: Bardo (website)
description: The download site for Bardo, private transcription for the Mac, drawn in the app's own dark-mode graphite.
colors:
  bard-purple: "oklch(66% 0.16 302)"
  ground: "oklch(17.8% 0.013 300)"
  ground-raised: "oklch(20.8% 0.013 300)"
  ground-high: "oklch(25.5% 0.014 300)"
  line: "oklch(32% 0.013 300)"
  line-strong: "oklch(46% 0.01 290)"
  text: "oklch(97% 0.004 290)"
  text-soft: "oklch(80% 0.008 290)"
  text-faint: "oklch(67% 0.01 290)"
  voice-you: "oklch(66% 0.17 252)"
  voice-2: "oklch(74% 0.15 60)"
  voice-3: "oklch(75% 0.17 148)"
typography:
  display:
    fontFamily: "Grenze, ui-serif, Georgia, serif"
    fontSize: "clamp(2.75rem, 4.4vw + 1rem, 5.5rem)"
    fontWeight: 600
    lineHeight: 1.04
    letterSpacing: "-0.015em"
  headline:
    fontFamily: "Grenze, ui-serif, Georgia, serif"
    fontSize: "clamp(2rem, 2.6vw + 1rem, 3.5rem)"
    fontWeight: 600
    lineHeight: 1.1
    letterSpacing: "-0.01em"
  title:
    fontFamily: "Geist Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "1.375rem"
    fontWeight: 700
    lineHeight: 1.2
    letterSpacing: "-0.02em"
  lead:
    fontFamily: "Geist Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "clamp(1.125rem, 0.4vw + 1rem, 1.3125rem)"
    fontWeight: 400
    lineHeight: 1.5
  body:
    fontFamily: "Geist Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "1rem"
    fontWeight: 400
    lineHeight: 1.55
  label:
    fontFamily: "Geist Variable, ui-sans-serif, system-ui, sans-serif"
    fontSize: "0.875rem"
    fontWeight: 500
    lineHeight: 1.43
  mono:
    fontFamily: "ui-monospace, SF Mono, Menlo, monospace"
    fontSize: "0.875rem"
    fontWeight: 400
rounded:
  sm: "0.45rem"
  lg: "0.75rem"
  xl: "1.05rem"
  window: "14px"
  2xl: "1.35rem"
  band: "28px"
  full: "9999px"
spacing:
  gutter-phone: "20px"
  gutter-tablet: "32px"
  gutter-desktop: "64px"
  stack-tight: "20px"
  block: "48px"
  column-gap: "64px"
  section-compact: "64px"
  section: "96px"
  container: "1360px"
components:
  button-primary:
    backgroundColor: "{colors.text}"
    textColor: "{colors.ground}"
    rounded: "{rounded.full}"
    padding: "0 24px"
    height: "48px"
    typography: "{typography.body}"
  button-outline:
    backgroundColor: "transparent"
    textColor: "{colors.text}"
    rounded: "{rounded.full}"
    padding: "0 16px"
    height: "44px"
    typography: "{typography.label}"
  button-outline-hover:
    backgroundColor: "{colors.ground-high}"
    textColor: "{colors.text}"
  nav-link:
    textColor: "{colors.text-soft}"
    typography: "{typography.label}"
    height: "44px"
  nav-link-current:
    textColor: "{colors.text}"
  panel-band:
    backgroundColor: "{colors.ground-raised}"
    rounded: "{rounded.band}"
    padding: "80px 24px"
  floating-capture:
    rounded: "{rounded.2xl}"
  hero-window:
    rounded: "{rounded.window}"
  code-block:
    backgroundColor: "{colors.ground}"
    textColor: "{colors.text}"
    rounded: "{rounded.xl}"
    padding: "20px"
    typography: "{typography.mono}"
---

# Design System: Bardo (website)

<!-- Scope: the website in web/ only (Astro + shadcn/Base UI + Tailwind v4). The macOS app's own UI is not described here. Recorded from the built pages on 2026-10-28. -->

## Overview

**Creative North Star: "The Graphite Window"**

The site is one more window of Bardo, not a separate marketing brand. It sits on the near-neutral graphite the Mac draws in dark mode (the same ground as the owner's portfolio covers, #121016), uses Grenze accents alongside Geist, and lets the real app speak: whole components cut from real captures float on that ground with a soft, deep shadow, readable at their own size. Everything else stays quiet so the screenshots carry the page.

Colour is a signal, never decoration. The bard's purple appears as brand and focus (focus rings, text selection, caret, and the 3D icon itself). Blue, orange and green appear only where speakers do: in the captures and in the speaker legend. The whole site is dark; there is no light band.

Density is calm and editorial without the editorial skeleton: one idea per section, a headline of a few words, one lead sentence, then the picture. Sections alternate text and picture on an asymmetric 4:7 grid; lists of facts are ruled ledgers, not cards.

**Key Characteristics:**
- Dark graphite ground with three tonal steps; hairline rules instead of boxes.
- Grenze SemiBold 600 for the wordmark and display/headline headings; Geist Variable for smaller headings, reading and controls.
- Real app components, whole and legible, floating with `shadow-float`.
- Purple only for brand and focus; speaker hues only for speakers.
- Pill-shaped controls; generously rounded floating pictures; 28px bands.
- One authored entrance (the hero window); everything else is plain state transitions.

## Colors

A graphite world with a single brand hue and three meaning-bound speaker hues; all neutrals carry a faint violet tint (hue 290-300) so the ground and the bard's purple belong together.

### Primary
- **Bard Purple** (`bard-purple`): the brand and the focus. Used for `:focus-visible` outlines, the `--ring` token, `::selection` (mixed at 45% into transparency), and the text caret. It is never a fill for buttons, cards or backgrounds; the 3D icon carries it visually.

### Secondary
- **Speaker Blue, "Tú"** (`voice-you`), **Speaker Orange** (`voice-2`), **Speaker Green** (`voice-3`): the three speaker colours from the app's waveform and avatars. They appear only as speaker dots in a legend that sits beside a capture of speakers, and inside the captures themselves.

### Neutral
- **Graphite Ground** (`ground`): page background, the `pre` code well, and the `theme-color`.
- **Raised Graphite** (`ground-raised`): the footer surface, and the verification panel.
- **High Graphite** (`ground-high`): outline-button hover, inline `code` background.
- **Hairline** (`line`): every rule and border (`border-border` is global); nav and footer dividers use it at 60%.
- **Strong Hairline** (`line-strong`): outline-button border, text-link underline at rest, scrollbar thumb, input border.
- **Text** (`text`): headings, current nav item, primary button fill.
- **Soft Text** (`text-soft`): leads, body copy in feature blocks, nav links at rest.
- **Faint Text** (`text-faint`): captions under CTAs, requirement lines, dates, group labels, step numerals.

### Named Rules
**The Colour Means Something Rule.** Purple is brand and focus; blue, orange and green are speakers. If a colour on a new surface cannot say which of those it is, it is graphite.

**The All Graphite Rule.** The site is dark from top to bottom. No light bands and no appearance switch: the owner removed the light/dark comparison on 2026-10-28.

**The Monochrome Primary Rule.** The primary action is near-white on graphite (`text` fill, `ground` label), not purple. The brand colour stays rare so focus remains visible.

## Typography

**Display Font:** Grenze SemiBold 600 from Google Fonts, self-hosted through Fontsource (Latin subset, including Spanish accents)
**Body Font:** Geist Variable
**Label/Mono Font:** Geist for labels; ui-monospace / SF Mono / Menlo for shell commands and paths

**Character:** Grenze adds a restrained medieval and literary accent to the Bardo wordmark and major headings. Geist keeps reading text, small headings and controls clear and familiar. Use only the upright 600 weight of Grenze; no decorative font on buttons, navigation links or transcript content.

### Hierarchy
- **Display** (Grenze 600, clamp 2.75rem to 5.5rem, line-height 1.04, -0.015em): the one `h1` per page. Hero line "Lo que se dice, por escrito." and page titles. Measure capped at 11-14ch.
- **Headline** (Grenze 600, clamp 2rem to 3.5rem, 1.1, -0.01em): every section `h2`, version numbers in Novedades, step numerals in Descargar (in faint text). Measure 14-16ch.
- **Title** (700, 1.375rem, 1.2, -0.02em): ledger row headings (`h3`), privacy terms, small panel titles.
- **Lead** (400, clamp 1.125rem to 1.3125rem, 1.5): the one sentence under a heading, in soft text. Measure 30-52ch.
- **Body** (400, 1rem, 1.55): list items and supporting copy; `text-wrap: pretty` on paragraphs, `balance` on headings.
- **Label** (500-600, 0.875rem): nav links, buttons (small), captions, footer column headings, group labels. Sentence case, never uppercase, never letter-spaced.
- **Mono** (0.875rem): `pre` command blocks and inline `code` at 0.88em on High Graphite.

### Named Rules
**The Short Measure Rule.** Headings are capped in `ch` (display 11-14ch, headline 14-16ch) and leads at 30-52ch, so every section reads as one idea.

**The Numbers Align Rule.** Sizes, versions and step numerals use `tabular-nums`.

## Layout

- **Container:** one `shell` utility: full width, capped at 1360px, centred, with a gutter of 64px (desktop), 32px (at or below 64rem), 20px (at or below 40rem). Nothing else defines page width.
- **Grid:** two-column splits on `minmax(0, 4fr) minmax(0, 7fr)` (text : picture), mirrored to 7:4 with `flip`; the hero uses 5:7; the download page's first-run block 6:5. Column gap 64px; collapses to one column below `lg` with 40px gap.
- **Section rhythm:** 96px vertical padding per section on desktop, 64px below `lg`; a heading block sits 48px above its content; heading to lead 20px; footer starts 128px (96px below `lg`) after the last section.
- **Hero:** fills the first viewport (`100dvh` minus the nav) on desktop, with waveform and transcript beside the heading. On phones its columns stack inside the same 20px shell gutter.
- **Ledgers:** facts, models, steps, versions and privacy terms are lists ruled by a top border on the list and a bottom border on each row, with a right-aligned tabular value where there is one. Three-up ledgers separate columns with vertical hairlines.
- **Responsive captures:** mobile uses complete, proportionally resized WebP sources at max-width 40rem. Never use a source cropped through a sentence or control. Main images fill the inner shell width; maintain its 20px phone gutter. The participants sheet uses 92% and the search stack 84% (max 320px), both centred.
- **Hit targets:** nav and footer links are at least 44px / 40px tall.

## Elevation & Depth

Depth comes from tonal layering of the graphite ground (ground, raised, high) plus one shadow that belongs to the app's own windows. Page structure never uses shadows; only pictures of the app lift off the page.

### Shadow Vocabulary
- **Float** (`box-shadow: 0 24px 48px -12px oklch(0% 0 0 / 0.55), 0 2px 6px oklch(0% 0 0 / 0.35)`): every floating app capture (hero window, feature components, search field, waveform, participants sheet).

### Named Rules
**The Only Things That Float Are the App Rule.** Shadows belong to app windows and components shown on the page. Sections, panels, ledgers and the footer are flat and use tone or a hairline instead.

## Shapes

- **Pills** (`rounded.full`) for every interactive control: buttons, the skip link, and the search-field capture.
- **All app captures** use `rounded-capture`: 12px by default and 4px on phones, controlled by `--capture-radius`. Do not assign a separate radius to individual screenshots.
- **Bands and panels** (the verification panel) use 28px corners and a hairline border on raised graphite.
- **Small surfaces:** code blocks `xl`, inline code `sm`.
- **Overlap:** in a feature picture, captures may overlap each other slightly (the participants sheet rides up 6% over the waveform), each keeping its own corners and shadow.
- Radii derive from one base, `--radius: 0.75rem`.

## Components

### Buttons
Calm, solid, Mac-like pills.
- **Shape:** full pill with a 1.5px border slot.
- **Primary:** near-white fill with graphite label, 48px tall, 24px horizontal padding, 16px semibold, leading 20px icon (the download arrow). Hover drops the fill to 85%.
- **Outline:** transparent with a Strong Hairline border, text label; 44px tall in the nav ("Descargar"). Hover lifts the border toward soft text and fills High Graphite.
- **States:** focus is a 2px Bard Purple outline offset 3px; press nudges down 1px; disabled is 55% opacity.
- **Transitions:** background, border, colour and translate over 200ms with `ease-out-expo` (`cubic-bezier(0.16, 1, 0.3, 1)`).

### Download CTA
The page's one conversion block: the primary button for the visitor's computer, then a faint caption line "Gratis. {requirements}. Versión {version}." The HTML shows the Mac's ("Descargar para Mac"); a native element asks the browser what the computer is and, when Windows installers exist, swaps to "Descargar para Windows" with an x64 (Intel or AMD) or ARM (Snapdragon) caption. Edge and Chrome tell ARM apart; other Windows browsers get x64, which Windows on ARM also runs. Below it, a text link "Otras descargas" leads to the computer ledger on Descargar. Until a release carries Windows installers (`windowsRelease` in `lib/site.ts`), a Windows visitor keeps the Mac button and reads "Bardo para Windows llega pronto." On phones show “Bardo es una app para Mac.” and “Comparte el enlace y ábrelo allí para descargarla.” above a full-width primary “Compartir enlace” button (or “Copiar enlace” when native sharing is absent). Keep mobile requirements concise; the desktop requirements and release version come from `lib/site.ts`.

### Live Waveform (signature)
The hero's picture is the app's live recording waveform with the Streaming Conversation under it, no card and no interface around them, drawn by the rules in `LiveRecorderView.swift` from generated levels: the Mac's audio rises above one shared line coloured by whoever speaks in the conversation under it (Valentina orange, Diego green; Tú is the blue microphone below), with the odd brief aside over the speaker and silence between passages, the microphone falls below it in blue (2px bars every 4px, height = level², a 3px gap each side of the line), older audio fades over the leading 35% into the page, the centre line is one gradient that eases toward the loudest voice's colour and back to the grey hairline in silence, and a thin red playhead fading at both ends marks where audio enters. It runs continuously, stops off screen and while hidden, and stays still under Reduce Motion.

### Ledger Lists
The house pattern for facts: ruled rows, a bold title on the left, a faint note beneath, an optional right-aligned tabular value. Used for transcription choices, download sizes, install steps, privacy terms and release notes.

On Descargar, "Elige tu equipo" is a ledger of the computers Bardo runs on (Mac, Windows, Windows en ARM): requirement note, file name in faint mono, and a 44px outline "Descargar" pill on the right (full width on phones), or "Pronto" in faint text while a platform has no release. The visitor's own row carries "Este equipo" in soft text. Download sizes gain Mac and Windows value columns (7rem and 6rem, headed in faint text) once Windows ships.

### Speaker Legend
A row of 10px round dots in the speaker hues followed by the speaker's name in soft 14px text, placed beside the capture it describes.

### Panel Band
Raised Graphite, 28px corners, hairline border, generous padding (48px on the verification panel). Holds a secondary utility.

### Page structure (home)
Three chapters, each with its own surface and scale, instead of a run of equal sections:
1. **Escribe** (base ground): the hero (headline, lead, CTA; on the right the live waveform with the streaming conversation under it), the full-width live-transcription window, and "Se lee como un documento" (moments with ⌥⌘N folded into its lead).
2. **Vuelve a cualquier conversación** (base ground, no cards): one centred heading, then a single composition like the owner's portfolio covers: the player window large in the middle, the Participantes sheet overlapping its lower left (clear of the lit lyric line) and the search field with its results list overlapping its right edge, all floating with the Float shadow. Under it, three short points in a ruled row: voices and names, search, listening with subtitles.
3. **Nada sale de tu Mac** (full-bleed `bard-field`, the only full-width colour on the page): display-size centred headline, one lead line, three privacy facts at lead size, link to Privacidad.
Then a calm close: the bard's head at 96px with a soft drop shadow, "Bardo" at display size, one line, the download CTA. The transcription options live on Descargar, not on the home page. Privacidad and Novedades end on a "Pruébalo en tu Mac" panel with the download.

### Streaming Conversation
Under the hero waveform: an invented meeting about Bardo (who is taking notes, nothing leaves the Mac, each voice gets a name, moments, search, skipped silences), looping. Centred, 17-21px medium text with 14px soft speaker labels and dots, three or four passages visible, older ones dimming into a top mask. Each passage takes its full space at once and the column glides once (700ms, `cubic-bezier(0.22, 1, 0.36, 1)`); its words then resolve through opacity (350ms each, 95ms apart, longer breaths after sentences). Stops off screen and while the tab is hidden; still under Reduce Motion.

### Text Links
Text-coloured, 1px underline in Strong Hairline offset 0.2em; the underline brightens to full text on hover over 200ms. Used for secondary routes ("Cómo instalarlo", "Todas las versiones").

### Navigation
- **Style:** a floating pill, sticky at the top with a 12px gap, centred and capped at 60rem: Raised Graphite at 75% with a strong backdrop blur and saturation (the page scrolls visibly under it, like a macOS toolbar), a hairline border and a soft offset shadow, 56px tall.
- **Content:** left, the bard's head (from the reference, tilted up like the icon, no square) 32px tall, centred with the word (with a small drop shadow) plus "Bardo" in 16px semibold; right, Novedades and Privacidad as 40px pill links in soft text (hover and current page fill High Graphite), then the primary "Descargar" button at 40px. On phones the button hides; the page's own CTA covers it.

### Footer
Raised Graphite surface with a top hairline: the 56px icon with name and one descriptive line, requirements and current version; two link columns ("Bardo", "Proyecto") with 14px semibold headings; a bottom bar with the credit and the cover line "Lo que se dice, por escrito." in faint text. Collapses to two columns below `lg`.

### Motion
Two authored motions, both native to the app. The hero's live waveform: bars glide left at 80px per second (one 2px bar every 4px, each 50ms of audio), paused only off screen, and drawn as a still frame under Reduce Motion. The hero conversation resolves each new passage word by word (opacity only, 350ms per word, 95ms apart), glides the column once per passage, stops off screen and while hidden, and stays still under Reduce Motion. Everything else is a 200ms state transition. `prefers-reduced-motion` collapses all durations.

## Do's and Don'ts

### Do:
- **Do** use the transparent 3D bard head (`assets/marca/bardo-mascota-ai-v2-*.webp`) in the nav, footer and closing sections. Use the square app icon (`assets/marca/icono-bardo*.webp`) for the download hero, favicons and touch icons. Allow for the transparent padding when setting the floating head’s displayed size.
- **Do** show the real app as whole, legible components (UI text at least 11px on screen) floating on graphite with the Float shadow, with a phone-specific source for small screens.
- **Do** keep Bard Purple for focus, selection, caret and the icon; keep speaker hues for speakers.
- **Do** set facts as ruled ledgers with tabular numbers instead of cards.
- **Do** keep one idea per section: a short bold headline, one lead sentence, one picture.
- **Do** take every page width from `shell` and every gutter from `--gutter`.

### Don't:
- **Don't** use the flat logo kit in `design/logo/kit` (or any flat wordmark or redraw of the bard) anywhere on the site.
- **Don't** fill buttons, backgrounds or panels with Bard Purple, or use speaker colours for anything that is not a speaker.
- **Don't** add a light band, a light page theme or an appearance switch; the owner removed it.
- **Don't** put shadows on sections, panels, ledgers or the footer; only app pictures float.
- **Don't** return to the editorial marketing skeleton the site replaced: no bento grid or slogan band. Grenze accents on headings are an explicit brand choice; keep the remaining interface in Geist.
- **Don't** crop captures into strips where UI text drops below legibility, or cut through sentences and buttons.
- **Don't** add another entrance animation; the hero window's is the only one.


## Brand marks
Two marks, both the original 3D bard: the complete floating bard head generated with ChatGPT Image from the original app icon (`assets/marca/bardo-mascota-ai-v2-128.webp` and `bardo-mascota-ai-v2-512.webp`; source and prompt in `design/mascota/image-v2/`, with real alpha transparency) for the nav, footer and closers, and the app icon on its dark squircle for favicons and the Descargar page. The flat logo kit in `design/logo/kit` is never used.


### Diffuse musical hero atmosphere
Four wide, curved string-like bands are woven into a violet pigment atmosphere across the entire hero. Gaussian cores and broader halos keep them recognizable as musical harmonics without sharp strokes or a separate bottom decoration. A restrained low-frequency cloud field joins the bands into the graphite background. Keep the violet visibly distinct at rest and the reading area quieter. Apply a 0.88 gain to the blended pigment to keep the accepted musical field slightly darker.

Cursor movement bends and excites the soft strings; scroll gently shifts them; a press sends one short, fading oscillation through the field. Native WebGL, no extra packages, low-resolution buffer capped at 960px on its longest side, and drift-corrected pacing up to 60 fps. Rendering pauses off-screen/when hidden. Reduce Motion shows a static field, including when changed live. A CSS gradient remains if WebGL is unavailable or its context is lost. The transcript uses opacity-only reveals to avoid repeated blur rasterization.

### Closing identity proportions
The closing brand uses a 160px transparent mascot image (144px on narrow screens), with a 12px optical shift left to balance the feather against the heavier face. The name uses Grenze 600 at 56–64px with no extra top margin; the 16–18px descriptor follows at 12px. Keep the download action 32px below the identity group. Transparent image padding counts as spacing; do not add another large gap above the name.


### Responsive and delivery constraints
Navigation fits at 320px with compact horizontal padding and a 20px brand label; all four routes are checked at 320, 390, 640, 768, 1024 and 1440px. Preserve the phone-specific capture sources, visible focus states, one h1 per page, valid section labels and manual share-link fallback.

Keep the shader and share control native. Only the hero conversation needs a React island (`client:visible`). Use local Latin WOFF2 fonts with early preload, explicit image dimensions and lazy decoding below the fold. Both canvases stop off screen/while hidden and follow live Reduce Motion changes. The waveform is capped at 60 draws/s and DPR 2; shader resolution remains separately bounded. Deployment/security rules and verification commands live in README.md.


### Phone composition refinements
Keep all app captures inside the shell padding and preserve their natural aspect ratio. At widths below 40rem, every app capture uses the same 4px radius so corners remain consistent without hiding toolbar controls. Use 24px vertical padding for regular sections (48px between adjacent content blocks), 24px between text and image, and 32px before feature lists. The coloured privacy chapter keeps 48px inner padding. Do not make every screenshot the same width: secondary sheets and search retain the smaller, centred proportions above.

On phones, do not reserve classic scrollbar tracks: `scrollbar-width: none` and the WebKit scrollbar fallback let section backgrounds span the full viewport. Keep the internal 20px shell padding on both sides of text and captures. Vertical scrolling remains native. Phone navigation now uses the normal shell gutter, a 24px Grenze brand label and an icon-only native navigation disclosure; do not squeeze the desktop link row onto a phone. Use the Apple-style square-and-up-arrow share icon.


### Mobile navigation and hero
Below 40rem, navigation keeps a 44px brand target and a 44px icon-only summary labelled “Navegación” for assistive technology. Its native details disclosure contains 48px links to Novedades, Privacidad and Descargar; Escape returns focus to the summary, clicking outside closes it, and navigation closes it. The desktop link row remains available from 40rem upward. Keep the dropdown inside the viewport without adding a framework or animation dependency.

The phone hero uses 32px top / 24px bottom padding, 20px between the heading, lead and CTA, and 24px before the demo. The lead is 16px with relaxed line height; the heading scales from 38 to 44px. The waveform is 112px tall and the transcript viewport 144px so the demonstration supports the first screen without dominating it.

The shader spans the full phone viewport without horizontal masks. Keep only the gentle 0.85–1.0 horizontal pigment modulation; do not pull the field into a central island. The privacy band and other full-width backgrounds must also reach both edges; only their content has shell padding.

For live transcription on a phone, use `transcripcion-en-vivo-panel-960.webp`: the complete detail pane of the actual app capture, excluding the two navigation columns. It keeps toolbar, title, progress, full text lines and player, in a near-square ratio. This is a reframing of the existing real capture, not a newly rendered narrow app window.


### Navigation disclosure motion
The mobile trigger is a 44px icon-only control, retaining an accessible navigation label and expanded state. Enhance the native details with `t-dropdown` from transitions.dev: top-right origin, 250ms opacity/scale open, 150ms close. Keep details open while the closing transition runs, make closing content inert, cancel stale timers/frames when reopening, and restore summary focus with Escape. Reduce Motion skips the transition and delays. The native disclosure remains usable without JavaScript because motion classes are installed only during enhancement.
