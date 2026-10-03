import { existsSync } from 'node:fs'
import { readFile, writeFile } from 'node:fs/promises'
import { ENTRENAMIENTO, clienteApi, cuadrosSinteticos, enviarCuadros, filasDelPaciente, finalizar, ok, percentil, sesionSintetica } from './rastreo-comun.mjs'

// Carga del rastreo por cuadros con transcripción en vivo a la vez (diseño 8.7, M2): S sesiones
// sintéticas, cada una con cuadros a la cadencia del servidor y un fragmento de audio cada 4 s
// (como la sala: a lo sumo 4 en vuelo). Con SIN_CUADROS=1 manda solo audio, la referencia sin
// emociones. Solo datos sintéticos; ver DEPLOY.md, «Medición en la c7i».
const base = process.env.ARGOS_BASE ?? 'http://localhost:8080'
const SESIONES = Number(process.env.SESIONES ?? 1)
const MINUTOS = Number(process.env.MINUTOS ?? 20)
const SIN_CUADROS = process.env.SIN_CUADROS === '1'
const docker = (process.env.ARGOS_DOCKER_OPENCV ?? 'run --rm -i --platform linux/amd64 argos-banco-rostro:local').split(' ')
const salida = process.env.ARGOS_SALIDA ?? `carga-rastreo-s${SESIONES}${SIN_CUADROS ? '-sin-cuadros' : ''}.json`
const CHUNK_MS = 4000
const MAX_CHUNKS_EN_VUELO = 4

const audios = await Promise.all([1, 2, 3].map((i) => readFile(new URL(`services/servicio-transcripcion/benchmark-fixtures/muestra-${i}.wav`, ENTRENAMIENTO))))

async function enviarAudio(cliente, sesionId, duracionMs) {
  const medicion = { latencias: [], rtfs: [], fallas: 0, noDisponibles: 0, baches: 0, maxEnVuelo: 0, enviados: 0 }
  const arranque = performance.now()
  const enVuelo = new Set()
  for (let nro = 0; performance.now() - arranque < duracionMs; nro++) {
    const proximo = arranque + (nro + 1) * CHUNK_MS
    if (enVuelo.size >= MAX_CHUNKS_EN_VUELO) {
      medicion.baches++
    } else {
      const form = new FormData()
      form.append('audio', new Blob([audios[nro % audios.length]], { type: 'audio/wav' }), `sintetico-${nro}.wav`)
      form.append('inicioCaptura', new Date(Date.now() - CHUNK_MS).toISOString())
      form.append('finCaptura', new Date().toISOString())
      const inicio = performance.now()
      const envio = cliente.api(`/api/sessions/${sesionId}/transcripcion?nroChunk=${nro}&canalOrigen=MICROFONO_AMBIENTE`, 'POST', form)
        .then((r) => {
          medicion.latencias.push(performance.now() - inicio)
          if (r.status < 200 || r.status >= 300) medicion.fallas++
          else if (r.datos?.fragmentoNoDisponible) medicion.noDisponibles++
          if (typeof r.datos?.rtf === 'number' && r.datos.rtf > 0) medicion.rtfs.push(r.datos.rtf * 1000)
        })
        .catch(() => { medicion.fallas++ })
        .finally(() => enVuelo.delete(envio))
      enVuelo.add(envio)
      medicion.enviados++
      medicion.maxEnVuelo = Math.max(medicion.maxEnVuelo, enVuelo.size)
    }
    const espera = proximo - performance.now()
    if (espera > 0) await new Promise((resolve) => setTimeout(resolve, espera))
  }
  await Promise.allSettled([...enVuelo])
  return medicion
}

/** Con ARGOS_CUADROS_ARCHIVO los cuadros se generan una vez y se reusan entre corridas. */
async function cuadrosDeArchivoOGenerados() {
  const archivo = process.env.ARGOS_CUADROS_ARCHIVO
  if (archivo && existsSync(archivo)) {
    const flujo = await readFile(archivo)
    const leidos = []
    for (let i = 0; i < flujo.length;) {
      const largo = flujo.readUInt32BE(i)
      leidos.push(flujo.subarray(i + 4, i + 4 + largo))
      i += 4 + largo
    }
    return leidos
  }
  const generados = await cuadrosSinteticos(docker, 600, 5)
  if (archivo) {
    await writeFile(archivo, Buffer.concat(generados.flatMap((cuadro) => {
      const largo = Buffer.alloc(4)
      largo.writeUInt32BE(cuadro.length)
      return [largo, cuadro]
    })))
  }
  return generados
}

const cliente = clienteApi(base)
await cliente.ingresar(process.env.ARGOS_EMAIL ?? 'demo@argos.local', process.env.ARGOS_PASSWORD ?? 'Demo1234')
const cuadros = SIN_CUADROS ? [] : await cuadrosDeArchivoOGenerados()
const sesiones = []
for (let i = 0; i < SESIONES; i++) sesiones.push(await sesionSintetica(cliente, ` carga ${i + 1}`))
console.log(`${SESIONES} sesiones, ${MINUTOS} min, ${SIN_CUADROS ? 'sin cuadros' : `${cuadros.length} cuadros en bucle`}: ${sesiones.join(' ')}`)

const duracionMs = MINUTOS * 60_000
const resultados = await Promise.all(sesiones.map(async (sesionId) => {
  try {
    const estado = ok(await cliente.api(`/api/sessions/${sesionId}/analisis-emocional/live-state`), 'live-state', true)
    const [cuadrosMedidos, audio] = await Promise.all([
      SIN_CUADROS ? null : enviarCuadros(base, cliente.token, sesionId, cuadros, duracionMs, estado.intervaloCuadroMs ?? 200),
      enviarAudio(cliente, sesionId, duracionMs),
    ])
    await finalizar(cliente, sesionId)
    const { filas, contiguas } = SIN_CUADROS ? { filas: [], contiguas: true } : await filasDelPaciente(cliente, sesionId)
    return {
      sesionId,
      cuadros: cuadrosMedidos && {
        enviados: cuadrosMedidos.cuadros,
        idaP50: percentil(cuadrosMedidos.idas, 0.5),
        idaP95: percentil(cuadrosMedidos.idas, 0.95),
        descartes: cuadrosMedidos.descartes,
        errores: cuadrosMedidos.errores,
        modos: cuadrosMedidos.modos,
        estados: cuadrosMedidos.estados,
        confirmadoS: cuadrosMedidos.primerConfirmadoS,
      },
      audio: {
        enviados: audio.enviados,
        latenciaP50: percentil(audio.latencias, 0.5),
        latenciaP95: percentil(audio.latencias, 0.95),
        rtfP50: audio.rtfs.length ? percentil(audio.rtfs, 0.5) / 1000 : null,
        rtfP95: audio.rtfs.length ? percentil(audio.rtfs, 0.95) / 1000 : null,
        fallas: audio.fallas,
        noDisponibles: audio.noDisponibles,
        baches: audio.baches,
        maxEnVuelo: audio.maxEnVuelo,
      },
      filas: { total: filas.length, contiguas, conLectura: filas.filter((f) => f.emocionPrincipal).length },
    }
  } catch (error) {
    await finalizar(cliente, sesionId).catch(() => {})
    return { sesionId, error: String(error) }
  }
}))

const resumen = { base, sesiones: SESIONES, minutos: MINUTOS, sinCuadros: SIN_CUADROS, fecha: new Date().toISOString(), resultados }
await writeFile(salida, JSON.stringify(resumen, null, 2))
console.log(JSON.stringify(resumen, null, 2))
