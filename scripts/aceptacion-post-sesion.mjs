import { readFile } from 'node:fs/promises'
import assert from 'node:assert/strict'
import { execFileSync } from 'node:child_process'

// Solo entorno local y datos sinteticos. Tokens viven exclusivamente en memoria.
const base = 'http://localhost:8080'
let token
let sesionId
let terminada = false
const probarAlmacenamiento = process.env.ARGOS_TEST_STORAGE === '1'
async function api(ruta, metodo = 'GET', cuerpo, autenticar = true) {
  const multipart = cuerpo instanceof FormData
  const respuesta = await fetch(base + ruta, {
    method: metodo,
    headers: { ...(autenticar && token ? { Authorization: `Bearer ${token}` } : {}), ...(!multipart && cuerpo ? { 'Content-Type': 'application/json' } : {}) },
    body: cuerpo ? multipart ? cuerpo : JSON.stringify(cuerpo) : undefined,
    signal: AbortSignal.timeout(120_000),
  })
  const texto = await respuesta.text()
  const datos = texto ? JSON.parse(texto) : {}
  return { status: respuesta.status, ...datos }
}
function ok(resultado, etapa) {
  assert.ok(resultado.status >= 200 && resultado.status < 300, `${etapa}: HTTP ${resultado.status}, ${resultado.codigo}`)
  console.log(`OK ${etapa}`)
  return resultado.datos
}
try {
  const login = ok(await api('/api/auth/login', 'POST', { email: 'demo@argos.local', password: 'Demo1234' }, false), 'login de prueba')
  token = login.accessToken
  assert.ok(token, 'Falta accessToken')
  const fecha = new Date().toLocaleDateString('en-CA', { timeZone: 'America/Argentina/Cordoba' })
  let paciente
  if (process.env.ARGOS_TEST_SESION_PREVIA) {
    const previa = ok(await api(`/api/sessions/${process.env.ARGOS_TEST_SESION_PREVIA}`), 'consultar prueba previa')
    assert.ok(previa.pacienteAlias.startsWith('E2E sintetico '), 'Solo se reutilizan pacientes de este script')
    paciente = { id: previa.pacienteId }
  } else {
    paciente = ok(await api('/api/patients', 'POST', { alias: `E2E sintetico ${Date.now()}`, fechaInicio: fecha }), 'crear paciente ficticio')
  }
  const sesion = ok(await api('/api/sessions', 'POST', { pacienteId: paciente.id, fecha, horaInicio: '23:00', horaFin: '23:30', tipo: 'PRESENCIAL' }), 'crear sesion')
  sesionId = sesion.id
  console.log(`SESION_PRUEBA ${sesionId}`)
  const alcances = ['CAPTURA_AUDIO', 'TRANSCRIPCION_LOCAL', 'CAPTURA_VIDEO', 'ANALISIS_EMOCIONAL_VIDEO']
  const solicitud = ok(await api(`/api/sessions/${sesionId}/consent-requests`, 'POST', { alcances }), 'solicitar consentimiento ficticio')
  const secreto = new URL(solicitud.urlPublica).pathname.split('/').pop()
  const publico = ok(await api(`/public/consents/${secreto}`, 'GET', undefined, false), 'leer consentimiento')
  ok(await api(`/public/consents/${secreto}/decision`, 'POST', { decision: 'ACEPTAR', alcancesAceptados: alcances, declaracionIdentidad: true, versionTerminos: publico.versionTerminos, retencionAudio: 'NO_GUARDAR', retencionVideo: 'NO_GUARDAR' }, false), 'aceptar solo datos sinteticos')
  ok(await api(`/api/sessions/${sesionId}/start`, 'PATCH', { alcances, dispositivos: { microfonoValidado: true, camaraConfirmada: true, camaraOmitida: false } }), 'iniciar sesion de prueba por API')
  const origen = Date.now() - 60_000
  for (let i = 1; i <= (probarAlmacenamiento ? 1 : 3); i++) {
    const audio = await readFile(new URL(`../../Argos-Entrenamiento/services/servicio-transcripcion/benchmark-fixtures/muestra-${i}.wav`, import.meta.url))
    if (probarAlmacenamiento) {
      const webm = execFileSync('docker', ['exec', '-i', 'argos-transcripcion', 'ffmpeg', '-hide_banner', '-loglevel', 'error', '-i', 'pipe:0', '-c:a', 'libopus', '-f', 'webm', 'pipe:1'], { input: audio, maxBuffer: 20 * 1024 * 1024 })
      const carga = ok(await api(`/api/sessions/${sesionId}/processing-recordings`, 'POST', { canalOrigen: 'MICROFONO_AMBIENTE', contentType: 'audio/webm' }), 'iniciar multipart real en S3 local')
      const rutaCarga = `/api/sessions/${sesionId}/processing-recordings/${carga.grabacionId}`
      const parte = ok(await api(`${rutaCarga}/parts`, 'POST', { numeroParte: 1 }), 'presignar parte')
      const subida = await fetch(parte.url, { method: 'PUT', body: webm, signal: AbortSignal.timeout(30_000) })
      assert.equal(subida.status, 200, 'Fallo subida directa')
      ok(await api(`${rutaCarga}/complete`, 'POST', { partes: [{ numeroParte: 1, etag: subida.headers.get('etag') }], tamanioBytes: webm.length }), 'confirmar audio para refinamiento')
    }
    const form = new FormData()
    form.append('audio', new Blob([audio], { type: 'audio/wav' }), `sintetico-${i}.wav`)
    const inicio = new Date(origen + (i - 1) * 15_000).toISOString()
    const fin = new Date(origen + i * 15_000).toISOString()
    form.append('inicioCaptura', inicio)
    form.append('finCaptura', fin)
    const ruta = `/api/sessions/${sesionId}/transcripcion?nroChunk=${i}&canalOrigen=MICROFONO_AMBIENTE`
    const t = ok(await api(ruta, 'POST', form), `ASR real fragmento ${i}`)
    assert.ok(t.texto?.trim() && !t.fragmentoNoDisponible, `ASR sin texto utilizable: ${i}`)
    const repetido = ok(await api(ruta, 'POST', form), `reintento idempotente ${i}`)
    assert.equal(repetido.id, t.id)
    const registro = ok(await api(`/api/sessions/${sesionId}/clinical-record`), 'lectura persistida')
    const guardado = registro.transcripciones.find(c => c.nroChunk === i)
    assert.equal(Date.parse(guardado.inicioChunk), Date.parse(inicio))
    assert.equal(Date.parse(guardado.finChunk), Date.parse(fin))
    console.log('OK timestamps originales conservados')
  }
  ok(await api(`/api/sessions/${sesionId}/end/prepare`, 'PATCH'), 'preparar cierre')
  ok(await api(`/api/sessions/${sesionId}/end`, 'PATCH'), 'finalizar')
  terminada = true
  if (probarAlmacenamiento) {
    let proceso
    for (let intento = 0; intento < 60; intento++) {
      proceso = ok(await api(`/api/sessions/${sesionId}/post-session`), 'consultar procesamiento')
      if (['COMPLETADO', 'ERROR'].includes(proceso.estado)) break
      await new Promise(resolve => setTimeout(resolve, 3000))
    }
    assert.equal(proceso.estado, 'COMPLETADO', 'Procesamiento no completado')
    const refinado = ok(await api(`/api/sessions/${sesionId}/clinical-record`), 'consultar texto refinado')
    assert.ok(refinado.transcripciones.some(t => t.estado === 'REFINADA'), 'No se aplico refinamiento real')
    console.log('OK refinamiento real post-sesion')
  }
  const denegada = await api(`/api/sessions/${sesionId}/nota`, 'POST')
  assert.ok(denegada.status >= 400, 'Generacion externa no debe ignorar consentimiento')
  console.log(`OK nota externa sin consentimiento rechazada: ${denegada.codigo}`)
  const registro = ok(await api(`/api/sessions/${sesionId}/clinical-record`), 'post-sesion persistida')
  if (!probarAlmacenamiento) assert.equal(registro.transcripciones.length, 3)
  const contenido = { motivo: 'Prueba automatizada con audio sintetico.', desarrollo: 'Validacion del recorrido local de post-sesion.', observaciones: 'Sin paciente real ni interpretaciones clinicas.', plan: 'Revisar el resultado tecnico de la prueba.' }
  ok(await api(`/api/sessions/${sesionId}/nota/manual`, 'POST', contenido), 'crear nota manual')
  ok(await api(`/api/sessions/${sesionId}/nota`, 'PUT', { ...contenido, desarrollo: 'Borrador sintetico revisado.' }), 'editar borrador')
  ok(await api(`/api/sessions/${sesionId}/nota/firmar`, 'POST'), 'firmar nota de prueba')
  const cambioFirmado = await api(`/api/sessions/${sesionId}/nota`, 'PUT', contenido)
  assert.ok(cambioFirmado.status >= 400, 'No debe editarse una nota firmada')
  console.log(`OK edicion de nota firmada rechazada: ${cambioFirmado.codigo}`)
  const noAutorizado = await api(`/api/sessions/${sesionId}/clinical-record`, 'GET', undefined, false)
  assert.ok([401, 403].includes(noAutorizado.status))
  console.log('OK acceso anonimo rechazado')
  console.log(`REVISAR http://localhost:5173/app/sesiones/${sesionId}/dashboard`)
} finally {
  if (sesionId && !terminada) {
    await api(`/api/sessions/${sesionId}/end/prepare`, 'PATCH').catch(() => {})
    await api(`/api/sessions/${sesionId}/end`, 'PATCH').catch(() => {})
    console.log('Limpieza: cierre solicitado para la sesion de prueba')
  }
}
