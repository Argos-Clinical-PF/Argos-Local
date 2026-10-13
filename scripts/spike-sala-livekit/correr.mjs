import { chromium } from 'playwright'
import crypto from 'node:crypto'
import http from 'node:http'
import { readFile } from 'node:fs/promises'
import { extname } from 'node:path'

// Spike WP0 (ADR-041). Dos Chrome con cámara y micrófono simulados entran a una sala LiveKit: el
// "paciente" publica y el "profesional" graba su audio por canal (un MediaRecorder reiniciado cada
// 4 s, igual que GrabacionSesion) y toma un JPEG del video cada 4 s. A mitad de la prueba el
// paciente sale y vuelve. Sale con código 1 si algún criterio falla.
//
// Por defecto apunta al LiveKit local del compose (modo --dev). Para el servidor de la EC2:
//   LIVEKIT_URL=wss://rtc.argosclinical.online LIVEKIT_API_KEY=... LIVEKIT_API_SECRET=... npm run spike
const URL_LK = process.env.LIVEKIT_URL ?? 'ws://localhost:7880'
const KEY = process.env.LIVEKIT_API_KEY ?? 'devkey'
const SECRET = process.env.LIVEKIT_API_SECRET ?? 'secret'
const PUERTO = Number(process.env.SPIKE_PUERTO ?? 8765)

const b64 = (o) => Buffer.from(JSON.stringify(o)).toString('base64url')
// Mismo formato que firma el backend: JWT HS256 estándar con el grant `video` de LiveKit.
function token(identity, sala) {
  const ahora = Math.floor(Date.now() / 1000)
  const h = b64({ alg: 'HS256', typ: 'JWT' })
  const p = b64({ iss: KEY, sub: identity, nbf: ahora - 5, exp: ahora + 600, video: { room: sala, roomJoin: true, canPublish: true, canSubscribe: true } })
  return `${h}.${p}.${crypto.createHmac('sha256', SECRET).update(`${h}.${p}`).digest('base64url')}`
}

// localhost es contexto seguro: getUserMedia funciona sin TLS.
const TIPOS = { '.html': 'text/html', '.mjs': 'text/javascript', '.js': 'text/javascript', '.map': 'application/json' }
const servidor = http.createServer(async (req, res) => {
  const ruta = decodeURIComponent(new URL(req.url, 'http://x').pathname)
  if (ruta.includes('..')) { res.writeHead(400).end(); return }
  try {
    const cuerpo = await readFile(new URL('.' + ruta, import.meta.url))
    res.writeHead(200, { 'Content-Type': TIPOS[extname(ruta)] ?? 'application/octet-stream' }).end(cuerpo)
  } catch { res.writeHead(404).end() }
}).listen(PUERTO)

const espera = (ms) => new Promise((r) => setTimeout(r, ms))
const sala = 'spike-' + crypto.randomUUID()
const browser = await chromium.launch({ channel: 'chrome', args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--autoplay-policy=no-user-gesture-required'] })
const abrir = async (rol, id) => {
  const pg = await (await browser.newContext()).newPage()
  await pg.goto(`http://localhost:${PUERTO}/sala.html?rol=${rol}&url=${encodeURIComponent(URL_LK)}&token=${token(id, sala)}`)
  return pg
}
try {
  const prof = await abrir('profesional', 'prof-spike')
  const pac = await abrir('paciente', 'pac-' + crypto.randomUUID())
  await espera(14000)
  console.log('>> el paciente sale 6 s')
  await pac.evaluate(() => window.room.disconnect())
  await espera(6000)
  console.log('>> el paciente vuelve a entrar')
  await pac.reload()
  await espera(14000)
  const r = await prof.evaluate(() => window.resultados)

  const canal = (c) => r.chunks.filter((x) => x.canal === c)
  const validos = (lista) => lista.filter((x) => x.durSeg && x.durSeg > 3)
  const audioPac = canal('AUDIO_COMPARTIDO_PACIENTE'), audioPro = canal('MICROFONO_PROFESIONAL')
  const tPac = (e) => r.eventos.filter((x) => x.e.startsWith(e) && x.e.includes('pac-')).length
  const criterios = [
    ['conecta con el token HS256', r.eventos.some((x) => x.e === 'conectado')],
    ['canal del profesional: chunks de ~4 s decodificables', validos(audioPro).length >= 6],
    ['canal del paciente: chunks de ~4 s decodificables', validos(audioPac).length >= 4],
    ['los canales son independientes', audioPac.length > 0 && audioPro.length > 0],
    ['frames JPEG del video del paciente', r.frames.length >= 5 && r.frames.every((f) => f.bytes > 1000)],
    ['reconexión: el paciente se vuelve a suscribir', tPac('suscripto audio') >= 2],
    ['sin errores de decodificación', r.errores.length === 0],
  ]
  for (const [nombre, ok] of criterios) console.log(`${ok ? 'OK  ' : 'FALLA'} ${nombre}`)
  console.log(`paciente: ${audioPac.map((c) => `#${c.n}:${c.durSeg}s`).join(' ')}`)
  console.log(`profesional: ${audioPro.map((c) => `#${c.n}:${c.durSeg}s`).join(' ')}`)
  if (r.errores.length) console.log('errores:', r.errores)
  process.exitCode = criterios.every(([, ok]) => ok) ? 0 : 1
} finally {
  await browser.close()
  servidor.close()
}
