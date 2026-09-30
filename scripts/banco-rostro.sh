#!/usr/bin/env bash
# Banco offline del rastreo facial (ADR-038, diseño 12): genera los cuadros con el mismo código de
# /infer/cuadro, los reproduce con el ProcesadorCuadros real del backend y calcula las métricas.
#
#   scripts/banco-rostro.sh calibracion      actores 01-04: candidatos de 6.12, parametros_congelados.json,
#                                            corrida principal, metrics.json y recalibracion.json
#   scripts/banco-rostro.sh holdout          actores 21-24, una sola vez, con los parámetros congelados;
#                                            sale con 1 si falla algún umbral H1-H8
#   scripts/banco-rostro.sh validar          un par, E1 + E2 + E7 adversario, 20 s por secuencia: prueba
#                                            la cadena de punta a punta (salida *-smoke, no se versiona);
#                                            ARGOS_BANCO_VALIDAR_ESCENARIOS y ..._RECORTE_MS la cambian
#   scripts/banco-rostro.sh limpiar [--todo] borra el volumen tmpfs y las imágenes huérfanas del banco;
#                                            con --todo también la imagen del banco, la de Maven y su caché
#
# Variables: ARGOS_BANCO_DATOS (RAVDESS, solo lectura), ARGOS_BANCO_ENTRENAMIENTO, ARGOS_BANCO_BACKEND,
# ARGOS_BANCO_PROCESOS (8), ARGOS_BANCO_TMPFS (4g), ARGOS_BANCO_CORRIDA (rastreo-rostro-<fecha>),
# ARGOS_BANCO_DISCO_MINIMO_GB (6), ARGOS_BANCO_CONSERVAR=1 no borra el tmpfs al terminar (depuración).
set -euo pipefail

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

replay() {
  local split=$1 configuraciones=$2 inicio=$SECONDS
  registro "replay $split ($configuraciones)"
  maven 'BancoRastreoRostroReplayTest#reproduceLaEntradaDelBanco' \
    "-Dargos.banco.entrada=/banco/$split/entrada" "-Dargos.banco.salida=/banco/$split/replay" \
    "-Dargos.banco.configuraciones=/banco/$split/$configuraciones"
  "${COMPOSE[@]}" run --rm -T generador cat "/banco/$split/replay/replay.json"
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

# Pasos comunes a partir de una generación: candidatos y congelado (solo calibración), corrida
# principal, sesiones de 9.4, consumidores reales y métricas.
cadena() {
  local split=$1 destino=$2 holdout=${3:-} inicio
  if [ -z "$holdout" ]; then
    registro "candidatos de 6.12"
    py models/banco_rastreo/metricas.py preparar --banco "/banco/$split" --salida "/banco/$split/candidatos.json"
    replay "$split" candidatos.json
    py models/banco_rastreo/metricas.py congelar --banco "/banco/$split" --replay "/banco/$split/replay" \
      --candidatos "/banco/$split/candidatos.json" --salida "/runs/$destino/parametros_congelados.json"
  fi
  py models/banco_rastreo/metricas.py preparar --banco "/banco/$split" --salida "/banco/$split/principal.json" \
    --parametros "/runs/$destino/parametros_congelados.json"
  replay "$split" principal.json
  inicio=$SECONDS
  py models/banco_rastreo/metricas.py sesiones --banco "/banco/$split" --replay "/banco/$split/replay" \
    --salida "/banco/$split/sesiones.json" --salida-java "/banco/$split/sesiones_java.json"
  maven 'CalibracionConsolidadorBancoTest#produceLasEntradasDeLaRecalibracion' \
    "-Dargos.banco.sesiones=/banco/$split/sesiones_java.json" "-Dargos.banco.salida=/banco/$split/consumidores.json"
  registro "consumidores de 9.4 listos en $((SECONDS - inicio)) s"
  inicio=$SECONDS
  py models/banco_rastreo/metricas.py evaluar --banco "/banco/$split" --replay "/banco/$split/replay" \
    --salida "/runs/$destino" --parametros "/runs/$destino/parametros_congelados.json" \
    --sesiones "/banco/$split/sesiones.json" --consumidores "/banco/$split/consumidores.json" \
    --commits "$(commits)" ${holdout:+"$holdout"}
  registro "métricas listas en $((SECONDS - inicio)) s: $ARGOS_BANCO_ENTRENAMIENTO/models/runs/$destino"
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
    mkdir -p "$ARGOS_BANCO_ENTRENAMIENTO/models/runs/$CORRIDA"
    generar calibracion 01,02,03,04
    cadena calibracion "$CORRIDA"
    cp "$ARGOS_BANCO_ENTRENAMIENTO/models/runs/$CORRIDA/parametros_congelados.json" "$CONGELADOS"
    registro "parámetros congelados: $CONGELADOS (sha256 $(shasum -a 256 "$CONGELADOS" | cut -d' ' -f1))"
    ;;
  holdout)
    [ -f "$CONGELADOS" ] || { echo "ABORTA: falta $CONGELADOS; primero calibracion" >&2; exit 2; }
    preparar
    mkdir -p "$ARGOS_BANCO_ENTRENAMIENTO/models/runs/$CORRIDA-holdout"
    cp "$CONGELADOS" "$ARGOS_BANCO_ENTRENAMIENTO/models/runs/$CORRIDA-holdout/parametros_congelados.json"
    huella=$(shasum -a 256 "$CONGELADOS" | cut -d' ' -f1)
    generar holdout 21,22,23,24 --parametros "/runs/$CORRIDA-holdout/parametros_congelados.json" \
      --holdout-autorizado "$huella"
    cadena holdout "$CORRIDA-holdout" --holdout
    ;;
  validar)
    preparar
    mkdir -p "$ARGOS_BANCO_ENTRENAMIENTO/models/runs/$CORRIDA-smoke"
    generar validacion 01,02 --escenarios "${ARGOS_BANCO_VALIDAR_ESCENARIOS:-E1,E2,E7:a-adversario}" \
      --pares 01-02 --recorte-ms "${ARGOS_BANCO_VALIDAR_RECORTE_MS:-20000}"
    cadena validacion "$CORRIDA-smoke"
    ;;
  limpiar)
    limpiar "${2:-}"
    ;;
  *)
    sed -n '2,20p' "$0"
    exit 2
    ;;
esac
