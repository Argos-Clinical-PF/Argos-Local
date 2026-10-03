import assert from 'node:assert/strict'
import { clienteApi, cuadrosSinteticos, enviarCuadros, filasDelPaciente, finalizar, ok, percentil, sesionSintetica } from './rastreo-comun.mjs'

// Rastreo del rostro por cuadros (ADR-038) de punta a punta contra el backend real con la bandera
// encendida (docker-compose.rastreo-e2e.yml). Solo entorno local y datos sintéticos.
const base = process.env.ARGOS_BASE ?? 'http://localhost:8080'
const contenedorEmociones = process.env.ARGOS_CONTENEDOR_EMOCIONES ?? 'argos-emociones'
const SEGUNDOS = Number(process.env.ARGOS_RASTREO_SEGUNDOS ?? 60)

const cliente = clienteApi(base)
let sesionId
let terminada = false
try {
  await cliente.ingresar('demo@argos.local', 'Demo1234')
  sesionId = await sesionSintetica(cliente)
  console.log(`SESION_PRUEBA ${sesionId}`)
  const estado = ok(await cliente.api(`/api/sessions/${sesionId}/analisis-emocional/live-state`), 'live-state')
  assert.equal(estado.modoCaptura, 'CUADROS', 'La bandera del rastreo no esta encendida para este profesional')

  const cuadros = await cuadrosSinteticos(['exec', '-i', contenedorEmociones], SEGUNDOS * 5, 5)
  console.log(`OK ${cuadros.length} cuadros sinteticos (${Math.round(cuadros[0].length / 1024)} KB el primero)`)
  const m = await enviarCuadros(base, cliente.token, sesionId, cuadros, SEGUNDOS * 1000, estado.intervaloCuadroMs ?? 200)
  const descartados = Object.values(m.descartes).reduce((a, b) => a + b, 0)
  const aceptados = m.cuadros - descartados - Object.values(m.errores).reduce((a, b) => a + b, 0)
  console.log(`idas p50 ${percentil(m.idas, 0.5)} ms, p95 ${percentil(m.idas, 0.95)} ms; aceptados ${aceptados}/${m.cuadros}; descartes ${JSON.stringify(m.descartes)}; errores ${JSON.stringify(m.errores)}; estados ${JSON.stringify(m.estados)}; modos ${JSON.stringify(m.modos)}; confirmado a los ${m.primerConfirmadoS?.toFixed(1)} s`)
  assert.deepEqual(m.errores, {}, 'hubo cuadros con error')
  assert.ok(m.primerConfirmadoS !== null && m.primerConfirmadoS <= 10, 'El paciente no se confirmo solo en 10 s')
  assert.ok(aceptados >= 0.9 * m.cuadros, 'Menos del 90 % de los cuadros llego al servicio')

  await finalizar(cliente, sesionId)
  terminada = true
  const { filas, contiguas } = await filasDelPaciente(cliente, sesionId)
  const leidas = filas.filter((f) => f.emocionPrincipal)
  console.log(`filas ${filas.length}, con lectura ${leidas.length}; emociones ${JSON.stringify(leidas.map((f) => f.emocionPrincipal))}`)
  assert.ok(filas.length >= Math.floor(SEGUNDOS / 4), `filas ${filas.length}, se esperaban al menos ${Math.floor(SEGUNDOS / 4)}`)
  assert.ok(contiguas, 'numeracion de ventanas no contigua')
  assert.ok(leidas.length >= Math.floor(0.6 * filas.length), 'Menos del 60 % de las ventanas tiene lectura con un solo rostro estable')
  console.log('OK rastreo por cuadros de punta a punta')
} finally {
  if (sesionId && !terminada) {
    await finalizar(cliente, sesionId).catch(() => {})
    console.log('Limpieza: cierre solicitado para la sesion de prueba')
  }
}
