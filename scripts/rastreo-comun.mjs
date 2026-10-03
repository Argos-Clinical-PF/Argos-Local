import { readFile } from 'node:fs/promises'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'

// Lo que comparten la aceptación y la carga del rastreo por cuadros (ADR-038). Solo datos
// sintéticos: el rostro es un retrato de dominio público de la NASA (Argos-Entrenamiento
// services/servicio-emociones/tests/fixtures/LICENCIAS.md), nunca RAVDESS.

/** Raíz de Argos-Entrenamiento, al lado de Argos-Local salvo que se indique otra. */
export const ENTRENAMIENTO = new URL(process.env.ARGOS_ENTRENAMIENTO ? `file://${process.env.ARGOS_ENTRENAMIENTO.replace(/\/?$/, '/')}` : '../../Argos-Entrenamiento/', import.meta.url)
export const RETRATO = new URL('services/servicio-emociones/tests/fixtures/nasa-s87-45893.jpg', ENTRENAMIENTO)
export const ALCANCES = ['CAPTURA_AUDIO', 'TRANSCRIPCION_LOCAL', 'CAPTURA_VIDEO', 'ANALISIS_EMOCIONAL_VIDEO']

export function clienteApi(base) {
  let token
  async function api(ruta, metodo = 'GET', cuerpo, autenticar = true) {
    const multipart = cuerpo instanceof FormData
    const respuesta = await fetch(base + ruta, {
      method: metodo,
      headers: { ...(autenticar && token ? { Authorization: `Bearer ${token}` } : {}), ...(!multipart && cuerpo ? { 'Content-Type': 'application/json' } : {}) },
      body: cuerpo ? multipart ? cuerpo : JSON.stringify(cuerpo) : undefined,
      signal: AbortSignal.timeout(120_000),
    })
    const texto = await respuesta.text()
    return { status: respuesta.status, ...(texto ? JSON.parse(texto) : {}) }
  }
  return {
    api,
    get token() { return token },
    async ingresar(email, password) {
      token = ok(await api('/api/auth/login', 'POST', { email, password }, false), 'login de prueba').accessToken
    },
  }
}

/** El enlace público lleva el secreto en el fragmento (`#t=`), que no llega a ningún registro. */
export function secretoDelEnlace(urlPublica) {
  const enlace = new URL(urlPublica)
  return new URLSearchParams(enlace.hash.slice(1)).get('t') ?? enlace.pathname.split('/').pop()
}

export function ok(resultado, etapa, silencioso = false) {
  assert.ok(resultado.status >= 200 && resultado.status < 300, `${etapa}: HTTP ${resultado.status}, ${resultado.codigo}`)
  if (!silencioso) console.log(`OK ${etapa}`)
  return resultado.datos
}

/** Paciente, sesión presencial y consentimiento ficticios, y la sesión iniciada por la API. */
export async function sesionSintetica({ api }, etiqueta = '') {
  const fecha = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Argentina/Cordoba' })
  const paciente = ok(await api('/api/patients', 'POST', { alias: `E2E sintetico ${Date.now()}${etiqueta}`, fechaInicio: fecha }), 'crear paciente ficticio', true)
  // Un turno libre del día: otra sesión todavía agendada en ese horario lo ocupa.
  let creada
  for (let turno = 0; turno < 48; turno++) {
    const minutos = (23 * 60 - turno * 30 + 24 * 60) % (24 * 60)
    const hora = (m) => `${String(Math.floor(m / 60)).padStart(2, '0')}:${String(m % 60).padStart(2, '0')}`
    creada = await api('/api/sessions', 'POST', { pacienteId: paciente.id, fecha, horaInicio: hora(minutos), horaFin: hora(minutos + 30), tipo: 'PRESENCIAL' })
    if (creada.codigo !== 'SESION_SOLAPAMIENTO') break
  }
  const sesion = ok(creada, 'crear sesion', true)
  const solicitud = ok(await api(`/api/sessions/${sesion.id}/consent-requests`, 'POST', { alcances: ALCANCES }), 'solicitar consentimiento ficticio', true)
  const secreto = secretoDelEnlace(solicitud.urlPublica)
  const publico = ok(await api(`/public/consents/${secreto}`, 'GET', undefined, false), 'leer consentimiento', true)
  ok(await api(`/public/consents/${secreto}/decision`, 'POST', { decision: 'ACEPTAR', alcancesAceptados: ALCANCES, declaracionIdentidad: true, versionTerminos: publico.versionTerminos, retencionAudio: 'NO_GUARDAR', retencionVideo: 'NO_GUARDAR' }, false), 'aceptar solo datos sinteticos', true)
  ok(await api(`/api/sessions/${sesion.id}/start`, 'PATCH', { alcances: ALCANCES, dispositivos: { microfonoValidado: true, camaraConfirmada: true, camaraOmitida: false } }), 'iniciar sesion', true)
  return sesion.id
}

export async function finalizar({ api }, sesionId) {
  ok(await api(`/api/sessions/${sesionId}/end/prepare`, 'PATCH'), 'preparar cierre', true)
  ok(await api(`/api/sessions/${sesionId}/end`, 'PATCH'), 'finalizar', true)
}

/** Las filas emocionales del paciente, en orden, y si la numeración es contigua desde 0. */
export async function filasDelPaciente({ api }, sesionId) {
  const registro = ok(await api(`/api/sessions/${sesionId}/clinical-record`), 'leer filas emocionales', true)
  const filas = (registro.analisisEmocional ?? []).filter((f) => f.hablante === 'PACIENTE').sort((a, b) => a.nroChunk - b.nroChunk)
  return { filas, contiguas: filas.every((fila, i) => fila.nroChunk === i) }
}

// Corre con Python y OpenCV en un contenedor: recorta el retrato con un movimiento lento, le suma
// ruido de sensor y devuelve cada JPEG precedido por su largo (4 bytes).
const GENERADOR = `
import math, struct, sys
import cv2, numpy as np
imagen = cv2.imdecode(np.frombuffer(sys.stdin.buffer.read(), np.uint8), cv2.IMREAD_COLOR)
total, cps, semilla = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3])
ruido = np.random.default_rng(semilla)
for n in range(total):
    t = n / cps
    x, y = int(80 + 60 * math.sin(t * 0.9)), int(60 + 30 * math.sin(t * 1.3))
    recorte = imagen[y:y + 360, x:x + 480].astype(np.float32) + ruido.normal(0, 6, (360, 480, 3))
    cuadro = cv2.resize(np.clip(recorte, 0, 255).astype(np.uint8), (320, 240), interpolation=cv2.INTER_AREA)
    jpeg = cv2.imencode('.jpg', cuadro, [cv2.IMWRITE_JPEG_QUALITY, 75])[1].tobytes()
    sys.stdout.buffer.write(struct.pack('>I', len(jpeg)) + jpeg)
`

/**
 * Cuadros del retrato en movimiento, 320 px de ancho. `docker` es el prefijo que ejecuta Python con
 * OpenCV: un `exec -i` a un contenedor que ya corre o un `run --rm -i` de una imagen.
 */
export async function cuadrosSinteticos(docker, total, cuadrosPorSegundo, semilla = 7) {
  const flujo = execFileSync('docker', [...docker, 'python', '-c', GENERADOR, String(total), String(cuadrosPorSegundo), String(semilla)],
    { input: await readFile(RETRATO), maxBuffer: 512 * 1024 * 1024 })
  const cuadros = []
  for (let i = 0; i < flujo.length;) {
    const largo = flujo.readUInt32BE(i)
    cuadros.push(flujo.subarray(i + 4, i + 4 + largo))
    i += 4 + largo
  }
  assert.equal(cuadros.length, total, 'el generador no entrego todos los cuadros')
  return cuadros
}

export function percentil(valores, p) {
  if (valores.length === 0) return null
  const orden = [...valores].sort((a, b) => a - b)
  return Math.round(orden[Math.min(orden.length - 1, Math.ceil(p * orden.length) - 1)])
}

/**
 * Manda cuadros a la cadencia que pide el servidor, uno en vuelo, durante `duracionMs`, y devuelve
 * lo medido. Los cuadros se repiten en bucle si la duración pide más de los que hay.
 */
export async function enviarCuadros(base, token, sesionId, cuadros, duracionMs, intervaloInicialMs = 200) {
  const medicion = { idas: [], descartes: {}, estados: {}, modos: {}, errores: {}, primerConfirmadoS: null, cuadros: 0 }
  const corridaId = crypto.randomUUID()
  const arranque = performance.now()
  let intervalo = intervaloInicialMs
  for (let seq = 0; performance.now() - arranque < duracionMs; seq++) {
    const tCaptura = Math.round(performance.timeOrigin + performance.now())
    const consulta = new URLSearchParams({ corridaId, seq: String(seq), tCapturaMs: String(tCaptura), encuadre: 'p:0a1b2c3d', sujeto: 'PACIENTE' })
    const inicio = performance.now()
    medicion.cuadros++
    try {
      const respuesta = await fetch(`${base}/api/sessions/${sesionId}/analisis-emocional/cuadros?${consulta}`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'image/jpeg' },
        body: cuadros[seq % cuadros.length],
        signal: AbortSignal.timeout(1_500),
      })
      const texto = await respuesta.text()
      medicion.idas.push(performance.now() - inicio)
      if (respuesta.status !== 200) {
        medicion.errores[respuesta.status] = (medicion.errores[respuesta.status] ?? 0) + 1
      } else {
        assert.ok(!/"(firma|huella)\w*"\s*:/i.test(texto), 'la respuesta no puede llevar firmas ni huellas')
        const datos = JSON.parse(texto).datos
        if (!datos.aceptado) medicion.descartes[datos.motivoDescarte] = (medicion.descartes[datos.motivoDescarte] ?? 0) + 1
        medicion.estados[datos.pista.estado] = (medicion.estados[datos.pista.estado] ?? 0) + 1
        medicion.modos[datos.modo] = (medicion.modos[datos.modo] ?? 0) + 1
        if (datos.pista.estado === 'CONFIRMADO' && medicion.primerConfirmadoS === null) {
          medicion.primerConfirmadoS = (performance.now() - arranque) / 1000
        }
        intervalo = datos.siguiente.intervaloMs
      }
    } catch (error) {
      medicion.errores[error.name] = (medicion.errores[error.name] ?? 0) + 1
    }
    const espera = intervalo - (performance.now() - inicio)
    if (espera > 0) await new Promise((resolve) => setTimeout(resolve, espera))
  }
  return medicion
}
