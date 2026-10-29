import { useEffect, useLayoutEffect, useRef, useState } from "react"

/*
 * A meeting arriving the way live transcription does. Each passage takes its full
 * space the moment it arrives (so the column glides once, never line by line), then
 * its words resolve in order through opacity, with a breath after each sentence. Older passages dim as they
 * rise. The meeting is invented; every feature it mentions is Bardo's.
 */

const KEEP = 4
/** Between words, and the extra breath after a sentence or a comma. */
const WORD_GAP = 95
const SENTENCE_BREATH = 340
const COMMA_BREATH = 150
/** How long a finished passage stays before the next one arrives. */
const DWELL = 1500

// `voice` matches the waveform above: 0 is your microphone, 1 and 2 arrive through the Mac.
const you = { speaker: "Tú", color: "bg-voice-you", voice: 0 }
const valentina = { speaker: "Valentina", color: "bg-voice-2", voice: 1 }
const diego = { speaker: "Diego", color: "bg-voice-3", voice: 2 }

const conversation = [
  { ...you, text: "Antes de partir: ¿alguien está tomando notas?" },
  { ...valentina, text: "Nadie. Bardo está transcribiendo mientras hablamos." },
  { ...diego, text: "¿Y esa grabación termina en algún servidor?" },
  { ...you, text: "No sale del Mac. Funciona incluso sin internet." },
  { ...valentina, text: "Y distingue cada voz. Después le ponemos nombre." },
  { ...diego, text: "O sea que ahora tengo que cumplir lo que prometo." },
  { ...you, text: "Exacto. Marca ese momento, por favor." },
  { ...valentina, text: "Listo. Queda en el minuto exacto, con una nota." },
  { ...diego, text: "¿Y si el viernes no me acuerdo de nada?" },
  { ...you, text: "Buscas una palabra y la escuchas desde ahí." },
  { ...valentina, text: "Hasta se salta los silencios cuando la reproduces." },
  { ...diego, text: "Bueno. Entonces cierro el cuaderno." },
]

const passages = conversation.map((line) => {
  const words = line.text.split(" ")
  let at = 0
  const delays = words.map((word) => {
    const delay = at
    at += WORD_GAP + (/[.?!:]$/.test(word) ? SENTENCE_BREATH : /,$/.test(word) ? COMMA_BREATH : 0)
    return delay
  })
  return { ...line, words, delays, duration: at }
})

interface Shown {
  key: number
  line: number
}

interface StreamingTranscriptProps {
  paused: boolean
  /** Called as a passage starts arriving: who speaks, and for how long in ms. */
  onSpeak: (voice: number, duration: number) => void
}

export function StreamingTranscript({ paused, onSpeak }: StreamingTranscriptProps) {
  const [shown, setShown] = useState<Shown[]>(() => [0, 1, 2].map((line) => ({ key: line, line })))
  /** The passage whose words are resolving; earlier ones are settled. */
  const [streamingKey, setStreamingKey] = useState<number | null>(null)
  const [resolved, setResolved] = useState(true)
  const [onScreen, setOnScreen] = useState(false)
  const rootRef = useRef<HTMLDivElement>(null)
  const columnRef = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const root = rootRef.current
    if (!root) return
    const motion = window.matchMedia("(prefers-reduced-motion: reduce)")
    let visible = false
    const sync = () => setOnScreen(visible && !document.hidden && !motion.matches)
    const observer = new IntersectionObserver(([entry]) => { visible = entry.isIntersecting; sync() })
    observer.observe(root)
    document.addEventListener("visibilitychange", sync)
    motion.addEventListener("change", sync)
    return () => {
      observer.disconnect()
      document.removeEventListener("visibilitychange", sync)
      motion.removeEventListener("change", sync)
    }
  }, [])

  // The next passage arrives once the current one has resolved and been read.
  useEffect(() => {
    if (paused || !onScreen) return
    const current = shown[shown.length - 1]
    const wait = streamingKey === null ? 700 : passages[current.line].duration + DWELL
    const timer = window.setTimeout(() => {
      const key = current.key + 1
      const line = (current.line + 1) % passages.length
      // The voice is heard from the first word to a beat after the last one.
      onSpeak(passages[line].voice, passages[line].duration + 350)
      setShown((list) => [...list, { key, line }].slice(-KEEP))
      setStreamingKey(key)
      setResolved(false)
    }, wait)
    return () => window.clearTimeout(timer)
  }, [paused, onScreen, shown, streamingKey, onSpeak])

  // Mount the new passage's words hidden, then let them resolve on the next frame.
  useEffect(() => {
    if (resolved) return
    let second = 0
    const first = requestAnimationFrame(() => {
      second = requestAnimationFrame(() => setResolved(true))
    })
    return () => {
      cancelAnimationFrame(first)
      cancelAnimationFrame(second)
    }
  }, [resolved])

  // A new passage grows the column from the bottom; ease it up instead of jumping.
  useLayoutEffect(() => {
    const column = columnRef.current
    if (!column) return
    let last = column.offsetHeight
    let animation: Animation | undefined
    const observer = new ResizeObserver(() => {
      const height = column.offsetHeight
      const grown = height - last
      last = height
      if (grown > 0 && !window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
        animation?.cancel()
        animation = column.animate([{ translate: `0 ${grown}px` }, { translate: "0 0" }], {
          duration: 700,
          easing: "cubic-bezier(0.22, 1, 0.36, 1)",
          composite: "add",
        })
      }
    })
    observer.observe(column)
    return () => { observer.disconnect(); animation?.cancel() }
  }, [])

  return (
    <div ref={rootRef} className="flex w-full justify-center">
      <div
        className="relative flex h-52 w-full flex-col justify-end overflow-hidden max-sm:h-36"
        style={{ maskImage: "linear-gradient(to bottom, transparent, black 60%)" }}
        aria-hidden="true"
      >
        <div ref={columnRef} className="flex flex-col gap-5">
          {shown.map(({ key, line }, index) => {
            const age = shown.length - 1 - index
            const passage = passages[line]
            const streaming = key === streamingKey
            const isIn = !streaming || resolved
            return (
              <div key={key} className="flex flex-col items-center gap-1.5 text-center">
                <p
                  className={`t-stream-w flex items-center gap-1.5 text-sm font-medium text-soft ${isIn ? "is-in" : ""}`}
                >
                  <span className={`size-1.5 rounded-full ${passage.color}`} />
                  {passage.speaker}
                </p>
                <p
                  className={`max-w-[34ch] text-[clamp(1.0625rem,0.5vw+0.9rem,1.3125rem)] leading-[1.4] font-medium tracking-[-0.01em] text-balance transition-colors duration-1000 ${age === 0 ? "text-foreground" : age === 1 ? "text-soft" : "text-faint"}`}
                >
                  {passage.words.map((word, i) => (
                    <span
                      key={i}
                      className={`t-stream-w ${isIn ? "is-in" : ""}`}
                      style={streaming ? { transitionDelay: `${passage.delays[i] + 120}ms` } : undefined}
                    >
                      {word}
                      {i < passage.words.length - 1 ? " " : ""}
                    </span>
                  ))}
                </p>
              </div>
            )
          })}
        </div>
      </div>
      <p className="sr-only">Ejemplo de una reunión transcrita en vivo, palabra por palabra.</p>
    </div>
  )
}
