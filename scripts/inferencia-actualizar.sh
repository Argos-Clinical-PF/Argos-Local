#!/usr/bin/env bash
# Pone en el host de inferencia GPU (ADR-037) la transcripción del manifiesto vigente. El user data
# (inferencia-arranque.sh) lo instala como /usr/local/bin/argos-inferencia-actualizar y lo corre al
# arrancar; Release MVP lo vuelve a correr por SSM cuando despliega transcripción. Recrea el
# contenedor solo si cambió la imagen o la bandera de diarización; si no, no toca nada.
#
# Si la imagen nueva no se puede bajar, saca la anterior: el enrutador de la app pasa a la CPU,
# que tiene la versión nueva, en vez de mezclar versiones.
set -euo pipefail

# Una corrida a la vez: la del user data y la de Release MVP pueden coincidir en los primeros
# minutos del host, y la segunda tiene que leer el manifiesto recién cuando la primera terminó.
exec 9>/run/argos-inferencia-actualizar.lock
flock 9

# shellcheck source=/dev/null
. /etc/argos-inferencia.env
REGISTRO="${REPOSITORIO%%/*}"
CONTENEDOR=argos-transcripcion
# Refinamiento post-sesión con large-v3 completo: en la GPU (FLEURS es_419, 80 audios, 2026-09-29) tiene
# menos errores que large-v3-turbo (2,52 % contra 2,94 % limpio; 2,78 % contra 3,16 % con ruido) y tarda
# 0,05 de la duración del audio. En vivo sigue large-v3-turbo, que responde en unos 0,2 s por fragmento.
MODELO_REFINAMIENTO=large-v3
CACHE=/var/lib/argos/hf-cache

log() { echo "$(date -u +%FT%TZ) argos-inferencia-actualizar: $*" >&2; }

reintentar() {
  local intentos="$1" espera="$2" n=1
  shift 2
  until "$@"; do
    if [ "$n" -ge "$intentos" ]; then
      log "$1 falló $n veces seguidas"
      return 1
    fi
    log "$1 falló ($n/$intentos); se reintenta en ${espera}s"
    n=$((n + 1))
    sleep "$espera"
  done
}

# Parámetro inexistente = apagada, como en deploy-mvp.sh; cualquier otro error se reintenta en vez
# de apagarla en silencio, porque con la bandera distinta de la app los fragmentos atendidos acá
# volverían sin agrupamiento.
# shellcheck disable=SC2329 # se invoca a través de reintentar
leer_diarizacion() {
  local salida
  if salida="$(aws ssm get-parameter --region "$REGION" --name /argos/mvp/diarizacion-enabled \
    --query Parameter.Value --output text 2>&1)"; then
    echo "$salida"
  elif grep -q ParameterNotFound <<<"$salida"; then
    echo false
  else
    return 1
  fi
}

# shellcheck disable=SC2329 # se invoca a través de reintentar
bajar_imagen() {
  aws ecr get-login-password --region "$REGION" \
    | docker login --username AWS --password-stdin "$REGISTRO" >/dev/null \
    && docker pull --quiet "$IMAGEN" >/dev/null
}

# Prueba con la librería que usa faster-whisper, no solo con nvidia-smi del host: recién arrancada
# la instancia, el driver o el runtime de contenedores pueden tardar en responder.
# shellcheck disable=SC2329 # se invoca a través de reintentar
gpu_lista() {
  nvidia-smi -L >/dev/null 2>&1 \
    && docker run --rm --gpus all --entrypoint python "$IMAGEN" \
      -c 'import ctranslate2, sys; sys.exit(0 if ctranslate2.get_cuda_device_count() > 0 else 1)' \
      >/dev/null 2>&1
}

MANIFIESTO="$(reintentar 5 10 aws s3 cp "s3://$BUCKET/deploy/manifests/current.json" - \
  --region "$REGION" --only-show-errors)"
TAG="$(python3 -c 'import json, sys; print(json.load(sys.stdin)["transcripcion"])' <<<"$MANIFIESTO")"
IMAGEN="$REPOSITORIO:$TAG-gpu"
DIARIZACION="$(reintentar 5 5 leer_diarizacion)"
CONFIGURACION="$IMAGEN diarizacion=$DIARIZACION refinamiento=$MODELO_REFINAMIENTO"

ACTUAL="$(docker inspect -f '{{ index .Config.Labels "argos.configuracion" }}' "$CONTENEDOR" 2>/dev/null || true)"
if [ "$ACTUAL" = "$CONFIGURACION" ] \
  && [ "$(docker inspect -f '{{.State.Running}}' "$CONTENEDOR" 2>/dev/null)" = "true" ]; then
  log "sin cambios ($CONFIGURACION)"
  exit 0
fi

log "aplicando $CONFIGURACION (antes: ${ACTUAL:-nada})"
if ! docker image inspect "$IMAGEN" >/dev/null 2>&1; then
  if ! reintentar 5 15 bajar_imagen; then
    log "no se pudo bajar $IMAGEN (¿la CI de Argos-Entrenamiento publicó la variante -gpu de ese tag?)"
    if [ -n "$ACTUAL" ]; then
      docker rm -f "$CONTENEDOR" >/dev/null
      log "se sacó la versión anterior: el enrutador sigue con la transcripción en CPU de la app"
    fi
    exit 1
  fi
  docker logout "$REGISTRO" >/dev/null || true
fi

reintentar 30 10 gpu_lista

# Mismo entorno que el servicio transcripcion de docker-compose.prod.yml con el .env de
# deploy-mvp.sh; solo cambian los modelos y el dispositivo. El de refinamiento se carga en el primer
# refinamiento y convive con el de vivo en la memoria de la GPU. Si cambia un valor allá, cambiarlo
# también acá.
# El /tmp del contenedor va en memoria: Starlette pasa a un archivo temporal toda subida de más de
# 1 MB, y el refinamiento manda el audio entero de la sesión.
docker rm -f "$CONTENEDOR" >/dev/null 2>&1 || true
docker run -d --name "$CONTENEDOR" --restart unless-stopped --gpus all -p 9000:9000 \
  -v "$CACHE":/root/.cache/huggingface \
  --tmpfs /tmp:rw,nosuid,nodev,size=1g \
  --label "argos.configuracion=$CONFIGURACION" \
  --log-driver awslogs \
  --log-opt awslogs-region="$REGION" \
  --log-opt awslogs-group="$GRUPO_LOGS" \
  --log-opt tag='inferencia/{{.Name}}' \
  --log-opt mode=non-blocking \
  --log-opt max-buffer-size=4m \
  --log-opt cache-max-size=10m \
  --log-opt cache-max-file=3 \
  --health-cmd "python -c \"import urllib.request; urllib.request.urlopen('http://localhost:9000/health', timeout=5)\"" \
  --health-interval 15s --health-timeout 10s --health-retries 30 --health-start-period 180s \
  -e NVIDIA_DRIVER_CAPABILITIES=compute,utility \
  -e WHISPER_MODEL=large-v3-turbo \
  -e WHISPER_REFINEMENT_MODEL="$MODELO_REFINAMIENTO" \
  -e WHISPER_DEVICE=cuda \
  -e WHISPER_COMPUTE_TYPE=float16 \
  -e DIARIZACION_ENABLED="$DIARIZACION" \
  -e WHISPER_IDIOMA=es \
  -e WHISPER_BEAM_SIZE=3 \
  -e WHISPER_REFINEMENT_BEAM_SIZE=5 \
  -e WHISPER_REFINEMENT_CPU_THREADS=6 \
  -e WHISPER_HOTWORDS= \
  -e WHISPER_MAX_REFINEMENT_AUDIO_BYTES=134217728 \
  -e WHISPER_CPU_THREADS=4 \
  -e WHISPER_NUM_WORKERS=2 \
  -e WHISPER_MAX_CONCURRENT_INFERENCES=2 \
  -e WHISPER_VAD_MIN_SILENCE_MS=250 \
  "$IMAGEN" >/dev/null
docker image prune -af >/dev/null || true

# Sin caché, el primer arranque baja el modelo de Hugging Face antes de responder "ok".
for _ in $(seq 1 80); do
  if SALUD="$(curl -fsS --max-time 5 http://127.0.0.1:9000/health 2>/dev/null)" \
    && grep -q '"estado":"ok"' <<<"$SALUD"; then
    log "listo: $(python3 -c 'import json, sys; d = json.load(sys.stdin); print(d["modelo"], d["device"], d["compute_type"], "diarizacion=%s" % d["diarizacion_enabled"])' <<<"$SALUD")"
    exit 0
  fi
  sleep 15
done
log "el contenedor no respondió \"estado\":\"ok\" en 20 minutos; últimas líneas:"
docker logs --tail 50 "$CONTENEDOR" 2>&1 || true
exit 1
