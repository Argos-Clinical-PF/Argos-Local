#!/usr/bin/env bash
# Pruebas de deploy-mvp.sh sin AWS ni Docker reales: docker y aws se reemplazan por dobles en el
# PATH. Cubren el gate de trabajo clínico activo, que el bundle se aplique recién después del gate
# y el vigía de contenedores unhealthy.
#
# Uso:  ./scripts/probar-deploy-mvp.sh
set -euo pipefail

RAIZ="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEPLOY="$RAIZ/scripts/deploy-mvp.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
FALLAS=0

afirmar() {
  local descripcion="$1"
  shift
  if "$@"; then
    echo "ok    $descripcion"
  else
    echo "FALLA $descripcion"
    FALLAS=$((FALLAS + 1))
  fi
}

mkdir -p "$TMP/bin"
cat > "$TMP/bin/docker" <<'EOS'
#!/usr/bin/env bash
echo "docker $*" >> "$DOBLE_DIR/llamadas"
case "$1" in
  inspect)
    if [ "${2:-}" = "-f" ] && [ "$3" = '{{.State.Running}}' ]; then
      [ "${BACKEND_CORRIENDO:-false}" = "true" ] && echo true && exit 0
      exit 1
    fi
    echo "ultimo chequeo fallido"
    ;;
  exec)
    [ "${WGET_FALLA:-false}" = "true" ] && exit 1
    printf '%s' "$RESPUESTA_SEGURIDAD"
    ;;
  ps)
    cat "$DOBLE_DIR/insalubres" 2>/dev/null || true
    ;;
  restart)
    echo "${*: -1}" >> "$DOBLE_DIR/reiniciados"
    ;;
esac
EOS
cat > "$TMP/bin/aws" <<'EOS'
#!/usr/bin/env bash
touch "$DOBLE_DIR/paso-el-gate"
cmp -s "$APP_DIR/Caddyfile" "$DOBLE_DIR/entrante/Caddyfile" && touch "$DOBLE_DIR/aplicado-antes-de-aws"
exit 1
EOS
chmod +x "$TMP/bin/docker" "$TMP/bin/aws"

# Como en la instancia: el workflow deja el bundle en entrante/ y la app tiene el release anterior.
mkdir -p "$TMP/entrante"
cp "$DEPLOY" "$RAIZ/scripts/refresh-ip-certificate.sh" "$RAIZ/docker-compose.prod.yml" \
  "$RAIZ/docker-compose.gpu.yml" "$RAIZ/Caddyfile" "$TMP/entrante/"

correr_deploy() {
  rm -rf "$TMP/llamadas" "$TMP/paso-el-gate" "$TMP/aplicado-antes-de-aws" "$TMP/salida" "$TMP/app"
  mkdir -p "$TMP/app"
  echo "caddy del release anterior" > "$TMP/app/Caddyfile"
  set +e
  env PATH="$TMP/bin:$PATH" DOBLE_DIR="$TMP" APP_DIR="$TMP/app" \
    BACKEND_TAG=sha-x FRONTEND_TAG=sha-x TRANSCRIPCION_TAG=sha-x EMOCIONES_TAG=sha-x \
    "$@" bash "$TMP/entrante/deploy-mvp.sh" > "$TMP/salida" 2>&1
  CODIGO=$?
  set -e
}

paso_el_gate() { [ -e "$TMP/paso-el-gate" ]; }
no_paso_el_gate() { [ ! -e "$TMP/paso-el-gate" ]; }
codigo_es() { [ "$CODIGO" = "$1" ]; }
salida_contiene() { grep -q "$1" "$TMP/salida"; }
no_consulto_backend() { ! grep -q 'docker exec' "$TMP/llamadas" 2>/dev/null; }
app_sin_tocar() { [ "$(ls -A "$TMP/app")" = "Caddyfile" ] && grep -qx "caddy del release anterior" "$TMP/app/Caddyfile"; }
aplicado_antes_de_aws() { [ -e "$TMP/aplicado-antes-de-aws" ]; }
app_completa() {
  local archivo
  for archivo in docker-compose.prod.yml docker-compose.gpu.yml Caddyfile deploy-mvp.sh refresh-ip-certificate.sh; do
    cmp -s "$TMP/entrante/$archivo" "$TMP/app/$archivo" || return 1
  done
  [ -x "$TMP/app/deploy-mvp.sh" ] && [ -x "$TMP/app/refresh-ip-certificate.sh" ]
}

SEGURO='{"codigo":"DESPLIEGUE_SEGURO","datos":{"seguro":true,"sesionesActivas":0}}'
OCUPADO='{"codigo":"DESPLIEGUE_CON_TRABAJO_ACTIVO","datos":{"seguro":false,"sesionesActivas":1}}'

echo "== Gate de trabajo clínico activo"
correr_deploy BACKEND_CORRIENDO=false RESPUESTA_SEGURIDAD="$OCUPADO"
afirmar "sin backend corriendo no hay sesión que proteger: sigue" paso_el_gate
afirmar "sin backend corriendo no consulta el endpoint" no_consulto_backend

correr_deploy BACKEND_CORRIENDO=true RESPUESTA_SEGURIDAD="$SEGURO"
afirmar "con seguro=true sigue" paso_el_gate
afirmar "pasado el gate aplica el bundle antes de llamar a AWS" aplicado_antes_de_aws
afirmar "pasado el gate copia los cinco archivos, con los scripts ejecutables" app_completa

correr_deploy BACKEND_CORRIENDO=true RESPUESTA_SEGURIDAD="$OCUPADO"
afirmar "con trabajo activo no toca nada" no_paso_el_gate
afirmar "con trabajo activo sale con 75" codigo_es 75
afirmar "con trabajo activo muestra los conteos" salida_contiene '"sesionesActivas":1'
afirmar "con trabajo activo deja la app con el release anterior" app_sin_tocar

correr_deploy BACKEND_CORRIENDO=true WGET_FALLA=true RESPUESTA_SEGURIDAD=""
afirmar "si el backend no responde, avisa y sigue" paso_el_gate
afirmar "si el backend no responde, lo dice" salida_contiene 'no respondió deployment-safety'

correr_deploy BACKEND_CORRIENDO=true FORZAR_DESPLIEGUE=true RESPUESTA_SEGURIDAD="$OCUPADO"
afirmar "forzar=true despliega aunque haya trabajo activo" paso_el_gate
afirmar "forzar=true ni siquiera consulta el endpoint" no_consulto_backend

# El rollback automático copia el bundle directo a la app y corre el script desde ahí.
rm -rf "$TMP/app" "$TMP/paso-el-gate" && mkdir -p "$TMP/app" && cp "$TMP/entrante/"* "$TMP/app/"
env PATH="$TMP/bin:$PATH" DOBLE_DIR="$TMP" APP_DIR="$TMP/app" FORZAR_DESPLIEGUE=true \
  BACKEND_TAG=sha-x FRONTEND_TAG=sha-x TRANSCRIPCION_TAG=sha-x EMOCIONES_TAG=sha-x \
  bash "$TMP/app/deploy-mvp.sh" > "$TMP/salida" 2>&1 || true
afirmar "corriendo desde la app (rollback) no se copia sobre sí mismo" paso_el_gate

echo "== Vigía de contenedores unhealthy"
# El vigía se instala desde un heredoc de deploy-mvp.sh; se extrae tal cual y solo se cambia el
# directorio de conteos (/run no existe fuera de la instancia).
sed -n "/^cat > \/usr\/local\/bin\/argos-vigia <<'EOS'$/,/^EOS$/p" "$DEPLOY" | sed '1d;$d' \
  | sed "s#/run/argos-vigia#$TMP/cuentas#" > "$TMP/argos-vigia"
chmod +x "$TMP/argos-vigia"
afirmar "el vigía se extrajo de deploy-mvp.sh" grep -q 'docker restart' "$TMP/argos-vigia"

vigia_con() {
  printf '%s' "$1" > "$TMP/insalubres"
  env PATH="$TMP/bin:$PATH" DOBLE_DIR="$TMP" bash "$TMP/argos-vigia" >> "$TMP/salida-vigia"
}
reiniciados() { paste -sd, - < "$TMP/reiniciados"; }
reiniciados_es() { [ "$(reiniciados)" = "$1" ]; }

: > "$TMP/reiniciados"
vigia_con $'argos-backend\n'
vigia_con $'argos-backend\n'
afirmar "dos chequeos unhealthy todavía no reinician" reiniciados_es ""
vigia_con $'argos-backend\n'
afirmar "al tercer chequeo seguido reinicia el contenedor" reiniciados_es "argos-backend"
vigia_con $'argos-backend\n'
vigia_con $'argos-backend\n'
afirmar "después de reiniciar vuelve a contar desde cero" reiniciados_es "argos-backend"

: > "$TMP/reiniciados"
vigia_con ""
vigia_con $'argos-transcripcion\n'
vigia_con $'argos-transcripcion\n'
vigia_con ""
vigia_con $'argos-transcripcion\n'
vigia_con $'argos-transcripcion\n'
afirmar "si se recupera entre chequeos, la cuenta se reinicia" reiniciados_es ""
vigia_con $'argos-transcripcion\nargos-emociones\n'
afirmar "cuenta cada contenedor por separado" reiniciados_es "argos-transcripcion"
afirmar "deja constancia del motivo en el journal" grep -q 'lleva 3 chequeos seguidos unhealthy' "$TMP/salida-vigia"

if [ "$FALLAS" -gt 0 ]; then
  echo "$FALLAS pruebas fallaron"
  exit 1
fi
echo "Todas las pruebas pasaron"
