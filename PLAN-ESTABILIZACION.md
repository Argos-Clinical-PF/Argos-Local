# Plan de estabilización tras la primera prueba con un psicólogo (19/09/2026)

Prueba real hecha el sábado 19/09 con la última versión desplegada, a través del dominio
(CloudFront). La instancia estuvo encendida de 13:58 a 17:16 (hora de Argentina) y la prueba fue en
esa ventana: los logs a revisar son los del 19/09 entre las 17:00 y las 20:16 UTC. Lo reportado, por
prioridad. Regla del plan: primero reproducir y medir, después corregir; cada corrección con su
prueba automática.

## P0. Se pierde trabajo clínico (semana del 21/09)

**1. La sesión se cerró sola a los 10 minutos y hubo que empezar de nuevo.**
Diez minutos exactos apunta a un temporizador, no a la RAM. Verificar en este orden:
- CloudFront corta las conexiones WebSocket inactivas a los 10 minutos. Si la sala usa WebSocket sin
  latido y trata el corte como fin de sesión, es esto. Revisar también el tiempo de respuesta de
  origen (30 s por defecto) contra los envíos de audio.
- Vencimiento del token de acceso: si la renovación falla o remonta la aplicación, la sala se cae.
- Logs del backend y del gateway de esa sesión (19/09, entre 14:00 y 17:00).
Corrección esperada: latido en el canal, reconexión automática sin cerrar la sesión, renovación de
token sin remontar la sala, y reanudar la misma sesión si la pestaña se recarga.
Nunca se había probado una sesión real de más de unos minutos: agregar una prueba de 20 minutos.

**2. Las grabaciones no se guardaron.**
Consecuencia probable de 1: la subida se completa al final y, si la sala muere, las partes se
pierden. Corrección: subir las partes durante la sesión, y al volver a entrar completar la grabación
con lo ya subido. Una caída no puede costar más que el último tramo.

**3. El consentimiento se registró, avanzó y el sistema lo devolvió al paso anterior.**
Hipótesis: el estado del asistente pre-sesión vive solo en memoria del navegador y se pierde al
renovarse el token o al refrescar la consulta; o el sondeo devuelve "pendiente" viejo y pisa el
estado. Corrección: la fuente de verdad es el backend; un consentimiento otorgado no retrocede.

## P1. Confunde, no pierde datos (semana del 21/09)

**4. El porcentaje del post-sesión sube a 50 %, vuelve a 0 % y repite.**
Causa observada: la nota generada no pasa la validación ("la nota clínica no cumple con el criterio
de observaciones") y se vuelve a generar; cada reintento reinicia el avance
(`ServicioProcesoPostSesion.estimar`). Son tres correcciones:
- El avance es monótono y por etapas: un reintento de la nota no lo baja ni lo reinicia.
- Revisar el criterio que falla contra notas reales de Bedrock: si rechaza notas clínicamente
  válidas, es demasiado estricto. Cada rechazo cuesta una generación completa, en tiempo y en dinero.
- Tope de reintentos (dos). Si sigue sin cumplir, la nota queda como borrador con un aviso de qué
  revisar, en vez de seguir en bucle. El profesional siempre la revisa antes de firmar.
Esos avisos son internos: no se le muestran al profesional durante el proceso.

**5. El panel lateral (Evidencia, Grabaciones, Asistente) es angosto y corta el texto.**
Hacerlo redimensionable arrastrando el borde (mínimo 320 px, máximo 60 %), con un botón para
ampliarlo a media pantalla, y que el texto de la evidencia envuelva en vez de cortarse.

**6. Cuesta encontrar menús, botones y acciones, en general.**
No es un botón puntual: es la facilidad de uso de toda la aplicación. Dos pasos:
- Prueba guiada con el psicólogo: cinco tareas sin ayuda (agendar, preparar e iniciar una sesión,
  encontrar una grabación, firmar una nota, ver la evolución de un paciente), anotando dónde duda.
- Con eso, corregir lo que más frene: una acción principal evidente por pantalla, nombres del menú
  en palabras del profesional, y un botón fijo "Iniciar sesión con <alias>" en la barra superior
  cuando hay una sesión agendada en los próximos 30 minutos.

## P2. Requisitos no funcionales, nunca probados (semana del 28/09)

Definir metas y medirlas, en vez de suponer que "es pesado":
- Equipo modesto: sala usable con 4 GB de RAM y CPU limitada (Chrome con CPU x6). Medir memoria
  del navegador durante 50 minutos: si crece sin techo, hay una fuga (fragmentos de audio o video
  retenidos). Bajar resolución y tasa del video grabado, y la frecuencia de captura de emociones.
- Carga inicial: dividir el paquete por rutas y cargar aparte gráficos y Back Office.
- Servidor: una sola instancia corre transcripción, emociones, backend y base. Medir con k6 cuántas
  sesiones simultáneas soporta y el p95 de la API (meta: menos de 500 ms).
- Resistencia: una sesión simulada de 50 minutos debe terminar sin cortes, con red intermitente y
  con una recarga de pestaña en el medio.
- Post-sesión: procesar una sesión debe tardar como mucho la mitad de su duración.

## Pendientes previos

- Respaldos automáticos de la base (hoy solo existe el snapshot manual `snap-0eb7e39e92e8599a8`).
- Pasos con root en la cuenta vieja de AWS, en orden: NS en Hostinger, cancelar el plan de
  CloudFront, cerrar la cuenta.

## Estado al 25/09/2026

Hecho y desplegado (Frontend PR #125, Backend PR #83):
- P0-1, P0-2 y P0-3 tenían una causa común: cada renovación del token de acceso (cada 15 minutos)
  cambiaba el token que ven los componentes y re-disparaba 25 efectos. La página de la sesión en vivo
  volvía a cargar, desmontaba la sala y cancelaba la grabación; el consentimiento volvía a su paso
  inicial. Además el reintento posterior al refresh salía con el token viejo. Corregido en el
  proveedor de sesión, con prueba. Los logs del 19/09 ya no existían (el deploy del 22/09 recreó los
  contenedores); la causa se encontró en el código.
- P1-4: la nota fallaba siempre en "observaciones" porque el prompt pedía una frase sin nada que
  citar. Prompt alineado, se conservan las frases citadas tras la reparación y el avance no vuelve a 0 %.
- P1-5: inspector de revisión rediseñado, ancho arrastrable, evidencia sin texto cortado.
- P1-6: acceso directo en la barra superior a la sesión en curso o por empezar.
- Otros: el layout remontaba la página en cada cambio de pestaña; grabaciones que requerían recargar
  para verse; foto de perfil apuntando a localhost.

Pendiente al 25/09 (tarde), resuelto esa noche salvo lo indicado en "Sigue pendiente":
- Prueba guiada de uso con el psicólogo (P1-6, parte de descubribilidad general).
- Recuperar las partes ya subidas de una grabación si el navegador se cierra o se cuelga.
- P2 completo.
- Respaldos automáticos de la base; SpringDoc expuesto en producción.

## Estado al 25/09/2026 (noche)

Hecho y desplegado (Frontend #128 a #130, Backend #84 y #85, Local #78):
- Grabaciones recuperables. Si el navegador se cierra, se cuelga o se corta la luz, el job de
  retención completa la carga con las partes que ya están en S3 (ListParts, racha continua desde
  la parte 1): a los 30 minutos de cerrada la sesión, a los 5 minutos de reabrir la sala o a las
  6 horas si la sesión nunca se cerró. No se recupera con la sesión cancelada, sin consentimiento
  de retención o con el plazo consentido vencido; se conserva ese plazo. La interfaz la marca
  "Parcial recuperada". Un WebM de MediaRecorder cortado se reproduce y permite buscar en Chrome.
  Una carga abandonada por una parte que no subió también conserva lo anterior.
- Cortes de red: cada parte reintenta unos 50 s (antes 7 s). Prueba e2e: 20 s sin red y una
  recarga en plena sesión; la sala se recupera sola y la transcripción sigue.
- Secretos: con ARGOS_EXIGIR_SECRETOS=true el backend no arranca si ENCRYPTION_KEY o JWT_SECRET
  faltan o tienen el valor de desarrollo (con la clave vacía el cifrado se desactivaba sin aviso).
- Ingreso más rápido: el código de Inicio se baja mientras se escribe la contraseña y sus cuatro
  consultas salen en paralelo apenas responde el login (una ida y vuelta en vez de tres).
- Despliegues: index.html sin caché y recarga automática si una pestaña pide un trozo que ya no
  existe; el log de nginx registra rt (total) y urt (backend) por pedido para medir el p95.
- Ingreso rediseñado (lente 3D de la marca) y Back Office con nombres accesibles en cada campo.

P2 medido (sala en vivo sobre la API simulada, Chrome con cámara y micrófono falsos):
- 50 minutos con la CPU frenada x6: sin cortes ni remontajes, 406 renovaciones del login,
  52 partes de grabación subidas. Salen 736 de 750 fragmentos: cada fragmento es un
  MediaRecorder nuevo y el relevo suma unos 76 ms por ciclo con esa CPU. Es deriva de cadencia;
  el texto final no se ve afectado porque el refinamiento usa la grabación continua.
- 20 minutos con recolección de basura forzada antes de cada muestra: memoria retenida estable
  en unos 24 MB (mín. 18, máx. 26). Sin fuga; la curva que subía sin forzar era basura pendiente.
- Carga inicial: ~113 KB en la primera visita (antes ~741 KB con el logo en PNG).

Sigue pendiente:
- Prueba guiada de uso con el psicólogo.
- k6 contra producción (capacidad y p95 de la API): necesita una cuenta de prueba. Mientras
  tanto el p95 real sale de `docker logs argos-frontend` (rt= y urt=).
- Tiempo de procesamiento post-sesión sobre una sesión real de 50 minutos.
- Decisiones abiertas: "Volver a la agenda" en plena sesión borra la grabación sin confirmar
  (igual que el fin de pantalla compartida o la pérdida de la cámara); lo no subido al caerse el
  navegador se pierde (hasta una parte de 5 MiB: unos 5 minutos de solo audio, 85 s de video),
  y guardarlo en el navegador choca con la política de no persistir datos de sesión (ARGOS-156).

## Transcripción y emociones (25/09/2026)

Transcripción, medido en la EC2 de producción sobre FLEURS es_419 (80 clips, 15,1 min, habla leída),
con las opciones del refinamiento; registro en Argos-Entrenamiento `models/runs/asr-refinamiento-fleurs-es`:

| Modelo | WER limpio | WER con ruido rosa 10 dB | RTF |
|---|---|---|---|
| small (en vivo) | 4,44 % | 4,82 % | 0,21 |
| medium | 3,16 % | 3,85 % | 0,50 |
| large-v3-turbo | 2,78 % | 3,00 % | 0,39 |

- Desplegado: el refinamiento post-sesión usa large-v3-turbo con 6 hilos (parámetro
  `whisper-refinement-model`); en vivo sigue small. Entrenamiento PR #47.
- Ruido: con 10 dB de ruido small pierde menos de medio punto. Demucs separa música de voz y no es un
  reductor de ruido para habla; un reductor (p. ej. DeepFilterNet) solo se adopta si mejora el WER
  sobre audio real de consultorio.
- Pendiente: medir sobre diálogo real (grabar 3 a 5 sesiones simuladas con consentimiento y su
  transcripción de referencia); guardar la transcripción por turnos de hablante en vez de ventanas
  fijas de 8 s (hoy un cambio de hablante dentro de una ventana queda bajo un solo hablante);
  verificar en una sesión virtual real que el micrófono no duplique la voz del paciente.

Emociones: el equipo ya comparó unos diez modelos faciales (incluido CLIP con LoRA) y ninguno superó
al desplegado; sobre conversación (MELD) el techo medido es ~0,20–0,24 de UAR. La fusión con voz se
retiró (ADR-027) porque bajaba el recall de tristeza. No se cambia el modelo sin datos propios. El
siguiente paso es un set de evaluación de ARGOS: las mismas sesiones simuladas, anotadas por un
psicólogo; con eso se prueban el descarte de cuadros de mala calidad (pose, desenfoque), la
calibración por persona y enet-b2.

