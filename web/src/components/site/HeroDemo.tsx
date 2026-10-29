import { useCallback, useEffect, useRef } from "react"
import { LiveRecorder } from "@/components/site/LiveRecorder"
import { StreamingTranscript } from "@/components/site/StreamingTranscript"

/**
 * The hero's one scene: the conversation below says who is speaking, and the
 * waveform above draws that voice while their words arrive. Both keep running;
 * each stops only off screen, and stays still under Reduce Motion.
 */
export function HeroDemo() {
  const speakerRef = useRef(-1)
  const silenceTimer = useRef(0)

  const onSpeak = useCallback((voice: number, duration: number) => {
    speakerRef.current = voice
    window.clearTimeout(silenceTimer.current)
    silenceTimer.current = window.setTimeout(() => {
      speakerRef.current = -1
    }, duration)
  }, [])

  useEffect(() => () => window.clearTimeout(silenceTimer.current), [])

  return (
    <div className="flex flex-col gap-2">
      <LiveRecorder paused={false} speakerRef={speakerRef} />
      <StreamingTranscript paused={false} onSpeak={onSpeak} />
    </div>
  )
}
