#!/usr/bin/env bash
# Banco offline del rastreo facial (ADR-038, diseño 12): genera los cuadros con el mismo código de
# /infer/cuadro, los reproduce con el ProcesadorCuadros real del backend y calcula las métricas.
#
#   scripts/banco-rostro.sh calibracion      actores 01-04: candidatos de 6.12, parametros_congelados.json,
#                                            corrida principal, metrics.json y recalibracion.json; los
#                                            valores de 9.4 quedan en parametros_congelados.json y su SHA-256
#                                            final en metrics.json (si la decisión 2 apaga la reidentificación
#                                            automática, la corrida principal se repite con el valor nuevo)
#   scripts/banco-rostro.sh holdout <metrics.json de la calibración>
#                                            actores 17-20 (ARGOS_BANCO_ACTORES_HOLDOUT; 21-24 ya se usaron), una sola vez, con los parámetros congelados cuyo
#                                            SHA-256 registró esa calibración; sale con 1 si falla algún
#                                            umbral H1-H8 o el control de 9.4
#   scripts/banco-rostro.sh validar          un par, E1 + E2 + E7 adversario, 20 s por secuencia: prueba
#                                            la cadena de punta a punta (salida *-smoke, no se versiona);
#                                            ARGOS_BANCO_VALIDAR_ESCENARIOS y ..._RECORTE_MS la cambian
#   scripts/banco-rostro.sh limpiar [--todo] borra el volumen tmpfs y las imágenes huérfanas del banco;
#                                            con --todo también la imagen del banco, la de Maven y su caché
#
# Variables: ARGOS_BANCO_DATOS (RAVDESS, solo lectura), ARGOS_BANCO_ENTRENAMIENTO, ARGOS_BANCO_BACKEND,
# ARGOS_BANCO_PROCESOS (8), ARGOS_BANCO_TMPFS (4g), ARGOS_BANCO_CORRIDA (rastreo-rostro-<fecha>),
# ARGOS_BANCO_DISCO_MINIMO_GB (6), ARGOS_BANCO_CONSERVAR=1 no borra el tmpfs al terminar (depuración),
# ARGOS_BANCO_CALIBRACION (el metrics.json de la calibración, en lugar del argumento del holdout),
# ARGOS_BANCO_FORZAR_HOLDOUT=<motivo> repite un holdout ya evaluado (lo invalida; queda registrado).
set -euo pipefail

ORIGEN="$PWD"
cd "$(dirname "$0")/.."
ARGOS_BANCO_ENTRENAMIENTO="$(cd "${ARGOS_BANCO_ENTRENAMIENTO:-../Argos-Entrenamiento}" && pwd)"
ARGOS_BANCO_BACKEND="$(cd "${ARGOS_BANCO_BACKEND:-../Argos-Backend}" && pwd)"
ARGOS_BANCO_DATOS="$(cd "${ARGOS_BANCO_DATOS:-../_datos-evaluacion/ravdess}" && pwd)"
export ARGOS_BANCO_ENTRENAMIENTO ARGOS_BANCO_BACKEND ARGOS_BANCO_DATOS
PROCESOS="${ARGOS_BANCO_PROCESOS:-8}"
CORRIDA="${ARGOS_BANCO_CORRIDA:-rastreo-rostro-$(date +%Y-%m-%d)}"
DISCO_MINIMO_GB="${ARGOS_BANCO_DISCO_MINIMO_GB:-6}"
COMPOSE=(docker compose -f docker-compose.banco-rostro.yml --profile banco)
VOLUMEN=argos-banco-rostro_banco
CONGELADOS="$ARGOS_BANCO_ENTRENAMIENTO/models/banco_rastreo/parametros_congelados.json"
RUNS="$ARGOS_BANCO_ENTRENAMIENTO/models/runs"
# Código de salida de `metricas.py evaluar` cuando la decisión 2 apagó la reidentificación automática.
RECONGELADO=3

registro() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

disco() {
  local libre_kb
  libre_kb=$(df -Pk "$HOME" | awk 'NR==2 {print $4}')
  if [ "$libre_kb" -lt $((DISCO_MINIMO_GB * 1024 * 1024)) ]; then
    echo "ABORTA: quedan $((libre_kb / 1024 / 1024)) GB libres; el mínimo es $DISCO_MINIMO_GB GB." >&2
    exit 2
  fi
}

limpiar() {
  registro "limpiando el volumen tmpfs y las imágenes huérfanas del banco"
  "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true
  docker volume rm -f "$VOLUMEN" >/dev/null 2>&1 || true
  docker image prune -f --filter label=argos.banco=rostro >/dev/null
  if [ "${1:-}" = "--todo" ]; then
    docker volume rm -f argos-banco-rostro_m2 >/dev/null 2>&1 || true
    docker image rm -f argos-banco-rostro:local maven:3.9-eclipse-temurin-21 >/dev/null 2>&1 || true
    docker builder prune -f --filter label=argos.banco=rostro >/dev/null 2>&1 || true
  fi
}

al_salir() {
  local codigo=$?
  if [ "${ARGOS_BANCO_CONSERVAR:-0}" != "1" ]; then
    limpiar
  fi
  exit "$codigo"
}

py() { "${COMPOSE[@]}" run --rm -T generador python "$@"; }

# Compila una copia del backend dentro del contenedor (el checkout se monta de solo lectura) y corre
# una prueba del banco con las propiedades dadas.
maven() {
  local prueba=$1
  shift
  # shellcheck disable=SC2016  # $0 y $@ los expande el sh del contenedor
  "${COMPOSE[@]}" run --rm -T replay sh -c '
    set -e
    mkdir -p /tmp/backend
    cp -r /fuente/pom.xml /fuente/src /tmp/backend/
    cd /tmp/backend
    mvn -q -B test -Dtest="$0" -Dsurefire.failIfNoSpecifiedTests=false -DargLine=-Xmx4g "$@"
  ' "$prueba" "$@"
}

# replay <split> <configuraciones> <directorio>: vacía /banco/<split>/<directorio> y reproduce ahí.
replay() {
  local split=$1 configuraciones=$2 directorio=$3 inicio=$SECONDS
  registro "replay $split ($configuraciones)"
  "${COMPOSE[@]}" run --rm -T generador rm -rf "/banco/$split/$directorio"
  maven 'BancoRastreoRostroReplayTest#reproduceLaEntradaDelBanco' \
    "-Dargos.banco.entrada=/banco/$split/entrada" "-Dargos.banco.salida=/banco/$split/$directorio" \
    "-Dargos.banco.configuraciones=/banco/$split/$configuraciones"
  "${COMPOSE[@]}" run --rm -T generador cat "/banco/$split/$directorio/replay.json"
  registro "replay $split listo en $((SECONDS - inicio)) s (incluye compilar el backend)"
}

commits() {
  local json="{" repo nombre
  for repo in "$ARGOS_BANCO_ENTRENAMIENTO" "$ARGOS_BANCO_BACKEND" "$(pwd)"; do
    nombre=$(basename "$(git -C "$repo" rev-parse --show-toplevel)")
    json+="\"$nombre\": {\"commit\": \"$(git -C "$repo" rev-parse HEAD)\", \"rama\": \"$(git -C "$repo" rev-parse --abbrev-ref HEAD)\", \"cambiosSinCommit\": $([ -z "$(git -C "$repo" status --porcelain)" ] && echo false || echo true)},"
  done
  echo "${json%,}}"
}

# La corrida principal con los parámetros congelados: replay, sesiones de 9.4, consumidores reales
# y métricas. Deja en CODIGO_EVALUAR la salida de `evaluar` (0, 1 en un holdout que falla, o
# RECONGELADO); cualquier otra falla corta el script.
principal() {
  local split=$1 destino=$2 holdout=${3:-} inicio
  py models/banco_rastreo/metricas.py preparar --banco "/banco/$split" --salida "/banco/$split/principal.json" \
    --parametros "/runs/$destino/parametros_congelados.json"
  replay "$split" principal.json replay
  inicio=$SECONDS
  py models/banco_rastreo/metricas.py sesiones --banco "/banco/$split" --replay "/banco/$split/replay" \
    --salida "/banco/$split/sesiones.json" --salida-java "/banco/$split/sesiones_java.json"
  maven 'CalibracionConsolidadorBancoTest#produceLasEntradasDeLaRecalibracion' \
    "-Dargos.banco.sesiones=/banco/$split/sesiones_java.json" "-Dargos.banco.salida=/banco/$split/consumidores.json"
  registro "consumidores de 9.4 listos en $((SECONDS - inicio)) s"
  inicio=$SECONDS
  CODIGO_EVALUAR=0
  py models/banco_rastreo/metricas.py evaluar --banco "/banco/$split" --replay "/banco/$split/replay" \
    --salida "/runs/$destino" --parametros "/runs/$destino/parametros_congelados.json" \
    --sesiones "/banco/$split/sesiones.json" --consumidores "/banco/$split/consumidores.json" \
    --commits "$(commits)" ${holdout:+"$holdout"} || CODIGO_EVALUAR=$?
  registro "métricas en $((SECONDS - inicio)) s (salida $CODIGO_EVALUAR)"
}

# Pasos comunes a partir de una generación: candidatos y congelado (solo calibración) y la corrida
# principal. En calibración, si la decisión 2 apaga la reidentificación automática después de la
# corrida principal, la corrida principal se repite una vez con los parámetros nuevos, así
# metrics.json y los valores de 9.4 corresponden a lo que queda congelado.
cadena() {
  local split=$1 destino=$2 holdout=${3:-}
  if [ -z "$holdout" ]; then
    registro "candidatos de 6.12"
    py models/banco_rastreo/metricas.py preparar --banco "/banco/$split" --salida "/banco/$split/candidatos.json"
    replay "$split" candidatos.json replay-candidatos
    py models/banco_rastreo/metricas.py congelar --banco "/banco/$split" --replay "/banco/$split/replay-candidatos" \
      --candidatos "/banco/$split/candidatos.json" --salida "/runs/$destino/parametros_congelados.json"
    "${COMPOSE[@]}" run --rm -T generador rm -rf "/banco/$split/replay-candidatos"
  fi
  principal "$split" "$destino" "$holdout"
  if [ -z "$holdout" ] && [ "$CODIGO_EVALUAR" -eq "$RECONGELADO" ]; then
    registro "decisión 2: reidentificación automática apagada; se repite la corrida principal"
    principal "$split" "$destino"
  fi
  if [ "$CODIGO_EVALUAR" -ne 0 ]; then
    echo "evaluar salió con $CODIGO_EVALUAR" >&2
    exit "$CODIGO_EVALUAR"
  fi
  registro "métricas listas: $RUNS/$destino"
}

generar() {
  local split=$1 actores=$2 inicio=$SECONDS
  shift 2
  registro "generando $split ($actores) con $PROCESOS procesos"
  py models/banco_rastreo/generar.py --datos /datos --salida "/banco/$split" --actores "$actores" \
    --procesos "$PROCESOS" "$@"
  registro "generación $split lista en $((SECONDS - inicio)) s"
}

preparar() {
  disco
  command -v docker >/dev/null || { echo "ABORTA: falta docker" >&2; exit 2; }
  registro "construyendo la imagen del banco (linux/amd64)"
  "${COMPOSE[@]}" build generador
  disco
  "${COMPOSE[@]}" down --remove-orphans >/dev/null 2>&1 || true
  docker volume rm -f "$VOLUMEN" >/dev/null 2>&1 || true
  trap al_salir EXIT
  "${COMPOSE[@]}" up -d retenedor
}

caso="${1:-}"
case "$caso" in
  calibracion)
    preparar
    mkdir -p "$RUNS/$CORRIDA"
    generar calibracion 01,02,03,04
    cadena calibracion "$CORRIDA"
    cp "$RUNS/$CORRIDA/parametros_congelados.json" "$CONGELADOS"
    registro "parámetros congelados (6.12 y 9.4): $CONGELADOS (sha256 $(shasum -a 256 "$CONGELADOS" | cut -d' ' -f1)," \
      "el registrado en $RUNS/$CORRIDA/metrics.json)"
    ;;
  holdout)
    [ -f "$CONGELADOS" ] || { echo "ABORTA: falta $CONGELADOS; primero calibracion" >&2; exit 2; }
    calibracion="${2:-${ARGOS_BANCO_CALIBRACION:-}}"
    case "$calibracion" in /* | "") ;; *) calibracion="$ORIGEN/$calibracion" ;; esac
    [ -f "$calibracion" ] || { echo "ABORTA: falta el metrics.json de la calibración (argumento o ARGOS_BANCO_CALIBRACION)" >&2; exit 2; }
    # Rutas físicas de los dos lados (en macOS /tmp es /private/tmp).
    calibracion="$(cd "$(dirname "$calibracion")" && pwd -P)/$(basename "$calibracion")"
    runs_real="$(cd "$RUNS" && pwd -P)"
    case "$calibracion" in
      "$runs_real"/*/metrics.json) ;;
      *) echo "ABORTA: $calibracion no es un metrics.json de $RUNS" >&2; exit 2 ;;
    esac
    # El generador compara el SHA-256 con el de metrics.json y rechaza un segundo holdout; acá solo
    # se evita pisar la carpeta de un holdout ya evaluado.
    if [ -e "$RUNS/$CORRIDA-holdout/metrics.json" ]; then
      echo "ABORTA: $RUNS/$CORRIDA-holdout ya tiene metrics.json; el holdout corre una vez (para repetirlo:" \
        "ARGOS_BANCO_FORZAR_HOLDOUT=<motivo> y otra ARGOS_BANCO_CORRIDA)" >&2
      exit 2
    fi
    preparar
    mkdir -p "$RUNS/$CORRIDA-holdout"
    cp "$CONGELADOS" "$RUNS/$CORRIDA-holdout/parametros_congelados.json"
    generar holdout "${ARGOS_BANCO_ACTORES_HOLDOUT:-17,18,19,20}" --parametros "/runs/$CORRIDA-holdout/parametros_congelados.json" \
      --calibracion "/runs/${calibracion#"$runs_real"/}" \
      ${ARGOS_BANCO_FORZAR_HOLDOUT:+--forzar-holdout "$ARGOS_BANCO_FORZAR_HOLDOUT"}
    cadena holdout "$CORRIDA-holdout" --holdout
    ;;
  validar)
    preparar
    mkdir -p "$RUNS/$CORRIDA-smoke"
    generar validacion 01,02 --escenarios "${ARGOS_BANCO_VALIDAR_ESCENARIOS:-E1,E2,E7:a-adversario}" \
      --pares 01-02 --recorte-ms "${ARGOS_BANCO_VALIDAR_RECORTE_MS:-20000}"
    cadena validacion "$CORRIDA-smoke"
    ;;
  limpiar)
    limpiar "${2:-}"
    ;;
  *)
    sed -n '2,24p' "$0"
    exit 2
    ;;
esac
