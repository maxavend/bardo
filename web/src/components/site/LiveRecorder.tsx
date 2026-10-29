import { useEffect, useRef, type RefObject } from "react"

/*
 * A simulated recording, drawn the way Bardo's live recorder draws it
 * (LiveRecorderView.swift): 2pt bars every 4pt, one per 50 ms, gliding left with
 * the clock; the Mac's audio rises above the line, coloured by whoever is speaking,
 * and your microphone falls below it in blue. Who speaks follows the conversation
 * shown under it (`speakerRef`), so the bars and the words arrive together. Older
 * audio fades toward the leading edge and a red playhead marks where audio enters. The levels are generated, not recorded.
 */

const BUCKET = 0.05
const BAR_WIDTH = 2
const STEP = 4
const PLAYHEAD_INSET = 10
const GAP = 3

/** Voice 0 is your microphone, below the line; the rest arrive through the Mac, above it. */
const VOICE_TOKENS = ["--voice-you", "--voice-2", "--voice-3"]

interface Bar {
  /** Level above the line (the Mac's audio) and which voice it is. */
  up: number
  upVoice: number
  /** Level below the line (your microphone). */
  down: number
  /** The centre line's colour here, eased toward whoever is loudest. */
  line: RGB
}

type RGB = [number, number, number]

/** Resolves any CSS colour (oklch included) to sRGB through a 1-pixel canvas. */
function toRGB(color: string): RGB {
  const probe = document.createElement("canvas").getContext("2d", { willReadFrequently: true })!
  probe.canvas.width = 1
  probe.canvas.height = 1
  probe.fillStyle = color
  probe.fillRect(0, 0, 1, 1)
  const [r, g, b] = probe.getImageData(0, 0, 1, 1).data
  return [r, g, b]
}

function mix(a: RGB, b: RGB, t: number): RGB {
  return [a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t]
}

function rgb(c: RGB) {
  return `rgb(${c[0] | 0} ${c[1] | 0} ${c[2] | 0})`
}

/** One voice's syllables: short swells with breaths between them. */
function createVoice() {
  let left = 0
  let length = 0.2
  let amp = 0.8
  return function level(loudness: number) {
    left -= BUCKET
    if (left <= 0) {
      const breath = Math.random() < 0.2
      length = breath ? 0.08 + Math.random() * 0.14 : 0.12 + Math.random() * 0.24
      left = length
      amp = breath ? 0.06 : (0.5 + Math.random() * 0.5) * loudness
    }
    const phase = 1 - left / length
    return Math.max(0, Math.min(1, amp * Math.sin(Math.PI * phase) + (Math.random() - 0.5) * 0.1))
  }
}

/**
 * A meeting: whoever `speakerRef` names is speaking (-1 is silence), and now and then
 * someone else drops a brief "mm" or "claro" over them. Until `synced` is set, it
 * invents its own turns, which fills the history drawn before the page settles.
 */
function createConversation(colors: RGB[], grey: RGB, speakerRef: RefObject<number>) {
  let synced = false
  const voices = colors.map(() => createVoice())
  let speaker = 0
  let turnLeft = 2
  let gapLeft = 0
  let aside = -1
  let asideLeft = 0
  let line: RGB = [...grey]

  function next(): Bar {
    if (synced) {
      speaker = speakerRef.current
      gapLeft = speaker < 0 ? 1 : 0
    } else if (gapLeft > 0) {
      gapLeft -= BUCKET
      if (gapLeft <= 0) {
        let nextSpeaker = speaker
        while (nextSpeaker === speaker) nextSpeaker = Math.floor(Math.random() * colors.length)
        speaker = nextSpeaker
        turnLeft = 0.9 + Math.random() * 2.1
      }
    } else {
      turnLeft -= BUCKET
      if (turnLeft <= 0) gapLeft = 0.12 + Math.random() * 0.33
    }
    if (asideLeft > 0) asideLeft -= BUCKET
    else if (gapLeft <= 0 && Math.random() < 0.02) {
      aside = speaker
      while (aside === speaker) aside = Math.floor(Math.random() * colors.length)
      asideLeft = 0.2 + Math.random() * 0.35
    }

    const levels = colors.map(() => Math.random() * 0.05)
    if (gapLeft <= 0) levels[speaker] = voices[speaker](1)
    if (asideLeft > 0) levels[aside] = Math.max(levels[aside], voices[aside](0.6))

    let upVoice = 1
    for (let v = 2; v < levels.length; v++) if (levels[v] > levels[upVoice]) upVoice = v
    const loudest = levels.indexOf(Math.max(...levels))
    // The line eases toward the colour of whoever is loudest, and greys out in silence.
    const target = levels[loudest] > 0.15 ? colors[loudest] : grey
    line = mix(line, target, levels[loudest] > 0.15 ? 0.16 : 0.08)

    return { up: levels[upVoice], upVoice, down: levels[0], line }
  }

  return {
    next,
    sync() {
      synced = true
    },
  }
}

interface LiveRecorderProps {
  paused: boolean
  /** Index of the voice speaking now (0 is you, below the line), or -1 for silence. */
  speakerRef: RefObject<number>
}

export function LiveRecorder({ paused, speakerRef }: LiveRecorderProps) {
  const canvasRef = useRef<HTMLCanvasElement>(null)
  const pausedRef = useRef(false)

  useEffect(() => {
    pausedRef.current = paused
  }, [paused])

  useEffect(() => {
    const canvas = canvasRef.current
    if (!canvas) return
    const context = canvas.getContext("2d")
    if (!context) return

    const style = getComputedStyle(canvas)
    const voiceColors = VOICE_TOKENS.map((token) => style.getPropertyValue(token).trim())
    const colors = {
      playhead: style.getPropertyValue("--rec").trim(),
      pausedHead: style.getPropertyValue("--text-faint").trim(),
    }
    const motion = window.matchMedia("(prefers-reduced-motion: reduce)")
    let reduceMotion = motion.matches
    const conversation = createConversation(
      voiceColors.map(toRGB),
      toRGB(style.getPropertyValue("--line-strong").trim()),
      speakerRef
    )
    const next = conversation.next
    const bars: Bar[] = []
    let elapsed = 0
    let last = performance.now()
    let frame = 0
    let visible = false
    let width = 0
    let height = 0
    let fade: CanvasGradient
    let heads: CanvasGradient[] = []

    // Enough history to fill the view from the first frame.
    const prefill = 260
    for (let i = 0; i < prefill; i++) bars.push(next())
    elapsed = prefill * BUCKET
    conversation.sync()

    function resize() {
      const rect = canvas!.getBoundingClientRect()
      const ratio = Math.min(window.devicePixelRatio || 1, 2)
      if (width === rect.width && height === rect.height && canvas!.width === Math.round(rect.width * ratio)) return
      width = rect.width
      height = rect.height
      canvas!.width = Math.round(width * ratio)
      canvas!.height = Math.round(height * ratio)
      context!.setTransform(ratio, 0, 0, ratio, 0, 0)
      // These masks depend only on geometry; reuse them across animation frames.
      fade = context!.createLinearGradient(0, 0, width, 0)
      fade.addColorStop(0, "rgba(0,0,0,0)")
      fade.addColorStop(0.35, "rgba(0,0,0,1)")
      heads = [colors.playhead, colors.pausedHead].map(red => {
        const head = context!.createLinearGradient(0, 0, 0, height)
        head.addColorStop(0, "rgba(0,0,0,0)")
        head.addColorStop(0.2, red)
        head.addColorStop(0.8, red)
        head.addColorStop(1, "rgba(0,0,0,0)")
        return head
      })
    }

    function draw() {
      if (width < 1 || height < 1) return
      const ctx = context!
      const isPaused = pausedRef.current
      ctx.clearRect(0, 0, width, height)
      const middle = height / 2
      const reach = middle - GAP - 6
      const newest = width - PLAYHEAD_INSET - BAR_WIDTH - 3
      // How far the newest bar has travelled since it arrived.
      const drift = ((elapsed / BUCKET) % 1) * STEP

      ctx.save()
      ctx.globalAlpha = isPaused ? 0.5 : 1
      // The line between the halves: one gradient whose colour drifts with the voices.
      const line = ctx.createLinearGradient(0, 0, width, 0)
      for (let age = 0; age < bars.length; age++) {
        const bar = bars[bars.length - 1 - age]
        const x = newest - age * STEP - drift + BAR_WIDTH / 2
        if (x < -STEP) break
        line.addColorStop(Math.min(1, Math.max(0, x / width)), rgb(bar.line))
      }
      ctx.fillStyle = line
      ctx.fillRect(0, middle - 0.75, newest + BAR_WIDTH, 1.5)

      for (let age = 0; age < bars.length; age++) {
        const bar = bars[bars.length - 1 - age]
        const x = newest - age * STEP - drift
        if (x < -BAR_WIDTH) break
        const up = bar.up * bar.up * reach
        const down = bar.down * bar.down * reach
        if (up > 2) {
          ctx.fillStyle = voiceColors[bar.upVoice]
          ctx.beginPath()
          ctx.roundRect(x, middle - GAP - up, BAR_WIDTH, up, BAR_WIDTH / 2)
          ctx.fill()
        }
        if (down > 2) {
          ctx.fillStyle = voiceColors[0]
          ctx.beginPath()
          ctx.roundRect(x, middle + GAP, BAR_WIDTH, down, BAR_WIDTH / 2)
          ctx.fill()
        }
      }
      ctx.restore()

      // Older audio fades out toward the leading edge instead of being cut off.
      ctx.save()
      ctx.globalCompositeOperation = "destination-in"
      ctx.fillStyle = fade
      ctx.fillRect(0, 0, width, height)
      ctx.restore()

      // Where audio enters: a thin red line that fades at both ends.
      const headX = width - PLAYHEAD_INSET / 2
      ctx.fillStyle = heads[isPaused ? 1 : 0]
      ctx.fillRect(headX - 0.75, 0, 1.5, height)

    }

    function tick(now: number) {
      frame = 0
      if (!visible || document.hidden || reduceMotion) return
      // The waveform needs 60 draws/s even on a 120/144 Hz screen.
      if (now - last < 1000 / 60 - 0.5) {
        frame = requestAnimationFrame(tick)
        return
      }
      const delta = Math.min(0.1, (now - last) / 1000)
      last = now
      if (!pausedRef.current) {
        const before = Math.floor(elapsed / BUCKET)
        elapsed += delta
        const after = Math.floor(elapsed / BUCKET)
        for (let i = before; i < after; i++) bars.push(next())
        if (bars.length > 600) bars.splice(0, bars.length - 600)
      }
      draw()
      frame = visible ? requestAnimationFrame(tick) : 0
    }

    resize()
    draw()
    const sizeObserver = new ResizeObserver(() => {
      resize()
      draw()
    })
    sizeObserver.observe(canvas)

    // Sleep off screen and in background tabs; respond to live OS preference changes.
    const schedule = () => {
      if (visible && !document.hidden && !reduceMotion && !frame) {
        last = performance.now()
        frame = requestAnimationFrame(tick)
      }
    }
    const stop = () => { cancelAnimationFrame(frame); frame = 0 }
    const viewObserver = new IntersectionObserver(([entry]) => {
      visible = entry.isIntersecting
      if (visible) schedule()
      else stop()
    })
    const onVisibility = () => { if (document.hidden) stop(); else schedule() }
    const onMotion = () => {
      reduceMotion = motion.matches
      stop()
      if (reduceMotion) draw()
      else schedule()
    }
    viewObserver.observe(canvas)
    document.addEventListener("visibilitychange", onVisibility)
    motion.addEventListener("change", onMotion)

    return () => {
      cancelAnimationFrame(frame)
      sizeObserver.disconnect()
      viewObserver.disconnect()
      document.removeEventListener("visibilitychange", onVisibility)
      motion.removeEventListener("change", onMotion)
    }
  }, [speakerRef])

  return (
    <canvas
      ref={canvasRef}
      className="h-64 w-full max-lg:h-56 max-sm:h-28"
      aria-hidden="true"
    />
  )
}
