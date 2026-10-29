// Diffuse musical strings woven through the whole hero. Input stays in GPU uniforms.
const FRAGMENT = `
#ifdef GL_FRAGMENT_PRECISION_HIGH
precision highp float;
#else
precision mediump float;
#endif
uniform vec2 u_res;
uniform float u_time, u_scroll, u_motion;
uniform vec3 u_pointer, u_press;
float hash(vec2 p) { return fract(sin(dot(p,vec2(127.1,311.7)))*43758.5453); }
float noise(vec2 p) {
  vec2 i=floor(p), f=fract(p), v=f*f*(3.0-2.0*f);
  return mix(mix(hash(i),hash(i+vec2(1,0)),v.x),mix(hash(i+vec2(0,1)),hash(i+vec2(1,1)),v.x),v.y);
}
void main() {
  vec2 uv=gl_FragCoord.xy/u_res;
  float aspect=u_res.x/u_res.y, t=u_time*u_motion*0.085;
  vec2 p=(uv-0.5)*vec2(aspect,1.0);
  vec2 delta=p-(u_pointer.xy-0.5)*vec2(aspect,1.0);
  float hover=exp(-dot(delta,delta)*2.0)*u_pointer.z*u_motion;
  vec2 flow=p*1.6+vec2(t*0.55,u_scroll*0.22-t*0.3);
  flow+=vec2(sin(flow.y*1.8+t),cos(flow.x*1.5-t))*0.24;
  flow+=delta*hover*0.18;
  float cloud=noise(flow+3.0)*0.74+noise(flow*2.0-7.0)*0.26;
  float depth=noise(flow*0.75+vec2(-t*0.2,8.0));
  float edges=smoothstep(0.0,0.14,uv.y)*smoothstep(0.0,0.16,1.0-uv.y);
  edges*=0.85+0.15*sin(uv.x*3.141593);
  float reading=mix(0.75,1.0,smoothstep(0.10,0.75,uv.x));
  // Wide, softly overlapping strings are part of the pigment itself.
  float age=u_press.z;
  float decay=exp(-age*1.5)*(1.0-smoothstep(2.5,3.5,age))*u_motion;
  float strings=0.0;
  for(int i=0;i<4;i++) {
    float n=float(i), phase=n*0.85;
    float center=0.17+n*0.17+sin(uv.x*3.2+phase+t*1.1)*0.10;
    center+=sin(uv.x*6.0-phase-u_time*0.30*u_motion)*0.022;
    center+=u_scroll*0.045+hover*sin(uv.x*8.0-u_time*1.5+phase)*0.014;
    center+=sin((uv.x-u_press.x)*16.0-age*6.0+phase)*exp(-abs(uv.x-u_press.x)*3.0)*decay*0.025;
    float d=(uv.y-center)/(0.028+n*0.006);
    strings+=exp(-d*d)*0.78+exp(-d*d*0.22)*0.22;
  }
  vec3 graphite=vec3(0.071,0.063,0.086);
  vec3 violet=mix(vec3(0.24,0.115,0.34),vec3(0.34,0.145,0.43),depth);
  float pigment=smoothstep(0.20,0.82,cloud);
  float density=(0.06+pigment*0.24+strings*0.28+hover*0.065)*edges*reading;
  vec2 hit=p-(u_press.xy-0.5)*vec2(aspect,1.0);
  float breath=exp(-dot(hit,hit)*2.5)*exp(-age*1.8)*u_motion;
  density+=breath*0.12*edges;
  gl_FragColor=vec4(mix(graphite,violet,min(density,0.65)*0.88),1.0);
}`
const VERTEX = `attribute vec2 a; void main(){gl_Position=vec4(a,0.0,1.0);}`

export function mountHeroShader(canvas: HTMLCanvasElement) {
const section = canvas?.closest("section")
if (!section) return
const gl = canvas.getContext("webgl", { antialias: false, alpha: false, depth: false, powerPreference: "low-power" })
if (!gl) return
const shaders: WebGLShader[] = []
let program: WebGLProgram | null = null
let buffer: WebGLBuffer | null = null
const dispose = () => {
  shaders.forEach(shader => gl.deleteShader(shader))
  if (buffer) gl.deleteBuffer(buffer)
  if (program) gl.deleteProgram(program)
}
try {
  const compile = (type: number, source: string) => {
    const shader = gl.createShader(type)
    if (!shader) throw new Error("Shader allocation failed")
    shaders.push(shader)
    gl.shaderSource(shader, source)
    gl.compileShader(shader)
    if (!gl.getShaderParameter(shader, gl.COMPILE_STATUS)) throw new Error(gl.getShaderInfoLog(shader) ?? "Shader compilation failed")
    return shader
  }
  program = gl.createProgram()
  if (!program) throw new Error("Program allocation failed")
  gl.attachShader(program, compile(gl.VERTEX_SHADER, VERTEX))
  gl.attachShader(program, compile(gl.FRAGMENT_SHADER, FRAGMENT))
  gl.linkProgram(program)
  if (!gl.getProgramParameter(program, gl.LINK_STATUS)) throw new Error(gl.getProgramInfoLog(program) ?? "Shader linking failed")
  gl.useProgram(program)
  buffer = gl.createBuffer()
  if (!buffer) throw new Error("Buffer allocation failed")
  gl.bindBuffer(gl.ARRAY_BUFFER, buffer)
  gl.bufferData(gl.ARRAY_BUFFER, new Float32Array([-1,-1,3,-1,-1,3]), gl.STATIC_DRAW)
  const attribute = gl.getAttribLocation(program, "a")
  gl.enableVertexAttribArray(attribute)
  gl.vertexAttribPointer(attribute, 2, gl.FLOAT, false, 0, 0)
} catch (error) {
  console.warn("Bardo hero uses its static background:", error)
  canvas.style.visibility = "hidden"
  dispose()
  return
}
const uniforms = Object.fromEntries(["res", "time", "pointer", "scroll", "press", "motion"].map(name => [name, gl.getUniformLocation(program!, `u_${name}`)]))
const motion = window.matchMedia("(prefers-reduced-motion: reduce)")
let reduced = motion.matches
let frame = 0, visible = false, lost = false, resized = true, scrolled = true
let progress = 0, previous = 0, lastDraw = 0
let bounds = section.getBoundingClientRect()
const start = performance.now()
const pointer = { x: 0.72, y: 0.55, strength: 0 }
const target = { ...pointer }
const press = { x: 0.72, y: 0.55, at: -10000 }
const clamp = (n: number) => Math.max(0, Math.min(1, n))
const draw = (now: number) => {
  if (lost) return
  if (resized) {
    const ratio = Math.min(window.devicePixelRatio || 1, 1.5) * 0.45
    const scale = Math.min(ratio, 960 / Math.max(canvas.clientWidth, canvas.clientHeight, 1))
    canvas.width = Math.max(1, Math.round(canvas.clientWidth * scale))
    canvas.height = Math.max(1, Math.round(canvas.clientHeight * scale))
    gl.viewport(0, 0, canvas.width, canvas.height)
    resized = false
  }
  if (scrolled) {
    bounds = section.getBoundingClientRect()
    progress = clamp(-bounds.top / Math.max(bounds.height, 1))
    scrolled = false
  }
  const ease = 1 - Math.exp(-Math.min((now - previous) / 1000, 0.1) * 12)
  pointer.x += (target.x - pointer.x) * ease
  pointer.y += (target.y - pointer.y) * ease
  pointer.strength += (target.strength - pointer.strength) * ease
  previous = now
  gl.uniform2f(uniforms.res, canvas.width, canvas.height)
  gl.uniform1f(uniforms.time, reduced ? 0 : (now - start) / 1000)
  gl.uniform3f(uniforms.pointer, pointer.x, pointer.y, reduced ? 0 : pointer.strength)
  gl.uniform1f(uniforms.scroll, reduced ? 0 : progress)
  gl.uniform3f(uniforms.press, press.x, press.y, Math.min((now - press.at) / 1000, 10))
  gl.uniform1f(uniforms.motion, reduced ? 0 : 1)
  gl.drawArrays(gl.TRIANGLES, 0, 3)
}
const tick = (now: number) => {
  frame = 0
  if (!visible || document.hidden || lost) return
  // Smooth 60 Hz input on high-refresh screens, with drift-corrected pacing.
  const interval = 1000 / 60
  const delta = now - lastDraw
  if (delta >= interval - 0.5 || reduced) {
    draw(now)
    lastDraw = delta < interval ? now : now - (delta % interval)
  }
  if (!reduced) frame = requestAnimationFrame(tick)
}
const schedule = () => {
  if (!frame && visible && !document.hidden && !lost) frame = requestAnimationFrame(tick)
}
const point = (x: number, y: number) => {
  if (scrolled) bounds = section.getBoundingClientRect()
  return { x: clamp((x - bounds.left) / Math.max(bounds.width, 1)), y: 1 - clamp((y - bounds.top) / Math.max(bounds.height, 1)) }
}
const onMove = (event: PointerEvent) => {
  if (!reduced && event.pointerType !== "touch") Object.assign(target, point(event.clientX, event.clientY), { strength: 1 })
}
const onLeave = () => { target.strength = 0 }
const pulse = (x: number, y: number) => {
  if (reduced) return
  Object.assign(press, point(x, y), { at: performance.now() })
  Object.assign(target, point(x, y), { strength: 1 })
}
const onPress = (event: PointerEvent) => pulse(event.clientX, event.clientY)
const onKey = (event: KeyboardEvent) => {
  if (event.repeat || (event.key !== "Enter" && event.key !== " ") || !(event.target instanceof HTMLElement)) return
  const rect = event.target.getBoundingClientRect()
  pulse(rect.left + rect.width / 2, rect.top + rect.height / 2)
}
const onScroll = () => { scrolled = true }
const onVisibility = () => {
  if (document.hidden) { cancelAnimationFrame(frame); frame = 0 }
  else schedule()
}
const onMotion = () => { reduced = motion.matches; cancelAnimationFrame(frame); frame = 0; schedule() }
const onLost = () => { lost = true; cancelAnimationFrame(frame); canvas.style.visibility = "hidden" }
const intersection = new IntersectionObserver(([entry]) => {
  visible = entry.isIntersecting
  if (visible) schedule()
  else { cancelAnimationFrame(frame); frame = 0 }
})
const resize = new ResizeObserver(() => { resized = true; scrolled = true; schedule() })
intersection.observe(canvas)
resize.observe(section)
section.addEventListener("pointermove", onMove, { passive: true })
section.addEventListener("pointerleave", onLeave, { passive: true })
section.addEventListener("pointerdown", onPress, { passive: true })
section.addEventListener("keydown", onKey)
window.addEventListener("scroll", onScroll, { passive: true })
document.addEventListener("visibilitychange", onVisibility)
motion.addEventListener("change", onMotion)
canvas.addEventListener("webglcontextlost", onLost)
draw(performance.now())
return () => {
  cancelAnimationFrame(frame)
  intersection.disconnect()
  resize.disconnect()
  section.removeEventListener("pointermove", onMove)
  section.removeEventListener("pointerleave", onLeave)
  section.removeEventListener("pointerdown", onPress)
  section.removeEventListener("keydown", onKey)
  window.removeEventListener("scroll", onScroll)
  document.removeEventListener("visibilitychange", onVisibility)
  motion.removeEventListener("change", onMotion)
  canvas.removeEventListener("webglcontextlost", onLost)
  dispose()
}
}
