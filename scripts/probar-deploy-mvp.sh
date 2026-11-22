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
echo "aws $*" >> "$DOBLE_DIR/llamadas"
touch "$DOBLE_DIR/paso-el-gate"
cmp -s "$APP_DIR/Caddyfile" "$DOBLE_DIR/entrante/Caddyfile" && touch "$DOBLE_DIR/aplicado-antes-de-aws"
case "$1 $2" in
  "sts get-caller-identity")
    [ -n "${PARAMETROS:-}" ] || exit 1
    echo 000000000000
    ;;
  "ssm get-parameter")
    while [ "$#" -gt 0 ]; do
      [ "$1" = "--name" ] && nombre="${2##*/}"
      shift
    done
    [ -n "${SSM_FALLA:-}" ] && [ "$nombre" = "$SSM_FALLA" ] && { echo "ThrottlingException: Rate exceeded" >&2; exit 255; }
    PARAMETROS="${PARAMETROS:-$DOBLE_DIR/ia-valida}"
    [ -f "$PARAMETROS/$nombre" ] || { echo "ParameterNotFound: $nombre" >&2; exit 254; }
    cat "$PARAMETROS/$nombre"
    ;;
  *)
    exit 1
    ;;
esac
EOS
cat > "$TMP/bin/curl" <<'EOS'
#!/usr/bin/env bash
case "$*" in
  *public-ipv4*) echo 192.0.2.10 ;;
  *) echo token ;;
esac
EOS
chmod +x "$TMP/bin/docker" "$TMP/bin/aws" "$TMP/bin/curl"

# Como en la instancia: el workflow deja el bundle en entrante/ y la app tiene el release anterior.
mkdir -p "$TMP/entrante"
cp "$DEPLOY" "$RAIZ/scripts/refresh-ip-certificate.sh" "$RAIZ/docker-compose.prod.yml" \
  "$RAIZ/Caddyfile" "$RAIZ/Caddyfile.modelos" "$TMP/entrante/"
mkdir -p "$TMP/ia-valida"
printf 'BEDROCK' > "$TMP/ia-valida/ia-proveedor"
printf 'us.anthropic.claude-sonnet-4-6' > "$TMP/ia-valida/ia-bedrock-modelo-nota"
printf 'us.anthropic.claude-sonnet-4-5-20250929-v1:0' > "$TMP/ia-valida/ia-bedrock-modelo-temas"

correr_deploy() {
  rm -rf "$TMP/llamadas" "$TMP/paso-el-gate" "$TMP/aplicado-antes-de-aws" "$TMP/salida" "$TMP/app"
  mkdir -p "$TMP/app"
  echo "caddy del release anterior" > "$TMP/app/Caddyfile"
  if [[ "${ARGOS_PRUEBA_PROTECCION_PREVIA:-false}" = true ]]; then
    printf 'ARGOS_TOKENIZACION_INTERNA=true\n' > "$TMP/app/.env"
  fi
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
leyo_la_cuenta() { grep -q '^aws sts get-caller-identity' "$TMP/llamadas"; }
app_completa() {
  local archivo
  for archivo in docker-compose.prod.yml Caddyfile Caddyfile.modelos deploy-mvp.sh refresh-ip-certificate.sh; do
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
afirmar "pasado el gate y la configuración de IA aplica el bundle antes de seguir con AWS" aplicado_antes_de_aws
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
rm -rf "$TMP/app" "$TMP/paso-el-gate" "$TMP/llamadas" && mkdir -p "$TMP/app" && cp "$TMP/entrante/"* "$TMP/app/"
env PATH="$TMP/bin:$PATH" DOBLE_DIR="$TMP" APP_DIR="$TMP/app" FORZAR_DESPLIEGUE=true \
  BACKEND_TAG=sha-x FRONTEND_TAG=sha-x TRANSCRIPCION_TAG=sha-x EMOCIONES_TAG=sha-x \
  bash "$TMP/app/deploy-mvp.sh" > "$TMP/salida" 2>&1 || true
afirmar "corriendo desde la app (rollback) no se copia sobre sí mismo" leyo_la_cuenta

echo "== Proveedor de IA"
parametros() {
  rm -rf "$TMP/ssm" && mkdir -p "$TMP/ssm"
  printf 'https://argos.example' > "$TMP/ssm/public-base-url"
  printf 'sk-ant-no-debe-salir' > "$TMP/ssm/anthropic-api-key"
  while [ "$#" -gt 0 ]; do
    printf '%s' "$2" > "$TMP/ssm/$1"
    shift 2
  done
}
no_llamo_compose() { ! grep -q 'docker \(login\|compose\)' "$TMP/llamadas" 2>/dev/null; }
env_contiene() { grep -qx "$1" "$TMP/app/.env"; }
env_sin_clave_publica() { ! grep -q '^ANTHROPIC_API_KEY=' "$TMP/app/.env"; }
cancela_sin_tocar() {
  codigo_es 78 && salida_contiene "Despliegue cancelado: $1" && app_sin_tocar && no_llamo_compose
}

NOTA=us.anthropic.claude-sonnet-4-6
TEMAS=us.anthropic.claude-sonnet-4-5-20250929-v1:0

parametros ia-bedrock-modelo-nota "$NOTA" ia-bedrock-modelo-temas "$TEMAS"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "sin ia-proveedor sale con 78, lo dice y deja la app como estaba" \
  cancela_sin_tocar 'no se pudo leer /argos/mvp/ia-proveedor\.'

parametros ia-proveedor BEDROCK ia-bedrock-modelo-nota "$NOTA" ia-bedrock-modelo-temas "$TEMAS"
correr_deploy PARAMETROS="$TMP/ssm" SSM_FALLA=ia-proveedor
afirmar "si SSM falla al leer ia-proveedor sale con 78, lo dice y deja la app como estaba" \
  cancela_sin_tocar 'no se pudo leer /argos/mvp/ia-proveedor\.'

parametros ia-proveedor ANTHROPIC ia-bedrock-modelo-nota "$NOTA" ia-bedrock-modelo-temas "$TEMAS"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "con ia-proveedor ANTHROPIC sale con 78, lo dice y deja la app como estaba" \
  cancela_sin_tocar "/argos/mvp/ia-proveedor es 'ANTHROPIC' y debe ser BEDROCK"

parametros ia-proveedor BEDROCK ia-bedrock-modelo-temas "$TEMAS"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "sin ia-bedrock-modelo-nota sale con 78, lo dice y deja la app como estaba" \
  cancela_sin_tocar 'no se pudo leer /argos/mvp/ia-bedrock-modelo-nota\.'

parametros ia-proveedor BEDROCK ia-bedrock-modelo-nota global.anthropic.claude-sonnet-4-6 ia-bedrock-modelo-temas "$TEMAS"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "con un modelo de la nota fuera de us. sale con 78, lo dice y deja la app como estaba" \
  cancela_sin_tocar '/argos/mvp/ia-bedrock-modelo-nota no coincide con el perfil de nota permitido en IAM\.'

parametros ia-proveedor BEDROCK ia-bedrock-modelo-nota "$NOTA"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "sin ia-bedrock-modelo-temas sale con 78, lo dice y deja la app como estaba" \
  cancela_sin_tocar 'no se pudo leer /argos/mvp/ia-bedrock-modelo-temas\.'

parametros ia-proveedor BEDROCK ia-bedrock-modelo-nota "$NOTA" ia-bedrock-modelo-temas anthropic.claude-haiku-4-5-20251001-v1:0
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "con un modelo de temas fuera de us. sale con 78, lo dice y deja la app como estaba" \
  cancela_sin_tocar '/argos/mvp/ia-bedrock-modelo-temas no coincide con el perfil de temas permitido en IAM\.'

parametros ia-proveedor BEDROCK ia-bedrock-modelo-nota us.anthropic.claude-sonnet-5-5 ia-bedrock-modelo-temas "$TEMAS"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "un perfil us. fuera de la lista IAM cancela el deploy" \
  cancela_sin_tocar '/argos/mvp/ia-bedrock-modelo-nota no coincide con el perfil de nota permitido en IAM\.'

parametros ia-proveedor BEDROCK ia-bedrock-modelo-nota "$NOTA" ia-bedrock-modelo-temas "$TEMAS"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "con BEDROCK y modelos us. escribe el proveedor" env_contiene 'IA_PROVEEDOR=BEDROCK'
afirmar "con BEDROCK y modelos us. escribe el modelo de la nota de SSM" env_contiene "ANTHROPIC_MODEL=$NOTA"
afirmar "con BEDROCK y modelos us. escribe el modelo de temas de SSM" env_contiene "ANTHROPIC_TOPICS_MODEL=$TEMAS"
afirmar "con BEDROCK no escribe la clave de la API pública" env_sin_clave_publica

afirmar "sin bandera de activación conserva la síntesis apagada" env_contiene 'COPILOTO_AGENTE_HABILITADO=false'
parametros ia-proveedor BEDROCK ia-bedrock-modelo-nota "$NOTA" ia-bedrock-modelo-temas "$TEMAS" copiloto-agente-habilitado true
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "la bandera habilita el agente explícitamente" env_contiene 'COPILOTO_AGENTE_HABILITADO=true'
parametros ia-proveedor BEDROCK ia-bedrock-modelo-nota "$NOTA" ia-bedrock-modelo-temas "$TEMAS" copiloto-agente-habilitado invalido
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "una bandera inválida cancela sin reemplazar el bundle" cancela_sin_tocar 'copiloto-agente-habilitado debe ser true o false\.'

echo "== Salida aislada de IA"
parametros ia-proveedor BEDROCK ia-bedrock-modelo-nota "$NOTA" ia-bedrock-modelo-temas "$TEMAS"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "la salida aislada se habilita explícitamente" env_contiene 'ARGOS_IA_SALIDA_AISLADA=false'
correr_deploy PARAMETROS="$TMP/ssm" SSM_FALLA=ia-salida-aislada
afirmar "si falla SSM se conserva la configuración de IA vigente" cancela_sin_tocar 'no se pudo leer la activación de la salida a IA.'
printf 'true' > "$TMP/ssm/ia-salida-aislada"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "el modo aislado exige la clave pública del autorizador" cancela_sin_tocar 'la clave pública del autorizador de IA falta o es inválida.'
CLAVE_AUTORIZADOR_FICTICIA="$(printf '%059d' 0)"
printf '%s' "$CLAVE_AUTORIZADOR_FICTICIA" > "$TMP/ssm/ia-autorizador-clave-publica"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "activar exige un alcance explícito" cancela_sin_tocar 'falta definir el alcance de la salida a IA.'
printf '11111111-1111-4111-8111-111111111111' > "$TMP/ssm/ia-salida-profesionales"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "la activación y la clave llegan al backend" env_contiene 'ARGOS_IA_SALIDA_AISLADA=true'
afirmar "la clave pública se publica en el entorno" env_contiene "ARGOS_IA_AUTORIZADOR_CLAVE_PUBLICA=$CLAVE_AUTORIZADOR_FICTICIA"
afirmar "el alcance del canario se conserva" env_contiene 'ARGOS_IA_SALIDA_PROFESIONALES=11111111-1111-4111-8111-111111111111'

echo "== Clave del índice de correo del portal"
parametros ia-proveedor BEDROCK ia-bedrock-modelo-nota "$NOTA" ia-bedrock-modelo-temas "$TEMAS"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "sin el parámetro SSM mantiene la etapa aditiva desactivada" env_contiene 'PORTAL_EMAIL_INDEX_KEY='
correr_deploy PARAMETROS="$TMP/ssm" SSM_FALLA=portal-email-index-key
afirmar "si falla SSM no reemplaza la configuración de correo" \
  cancela_sin_tocar 'no se pudo leer la clave del índice de correo del portal\.'

printf 'valor-malformado' > "$TMP/ssm/portal-email-index-key"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "una clave inválida cancela sin copiar el bundle" \
  cancela_sin_tocar 'la clave del índice de correo del portal tiene un formato inválido\.'
sin_valor_del_secreto() { ! grep -Fq valor-malformado "$TMP/salida"; }
afirmar "el error omite el valor leído de SSM" sin_valor_del_secreto

CLAVE_PORTAL_FICTICIA=MDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWY=
printf '%s' "$CLAVE_PORTAL_FICTICIA" > "$TMP/ssm/portal-email-index-key"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "la clave válida pasa al entorno privado" env_contiene "PORTAL_EMAIL_INDEX_KEY=$CLAVE_PORTAL_FICTICIA"

afirmar "sin bandera conserva el modo aditivo" env_contiene 'PORTAL_EMAIL_SOLO_INDICE=false'
printf 'true' > "$TMP/ssm/portal-email-solo-indice"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "con la clave y la bandera usa solo el índice" env_contiene 'PORTAL_EMAIL_SOLO_INDICE=true'
correr_deploy PARAMETROS="$TMP/ssm" SSM_FALLA=portal-email-solo-indice
afirmar "si no puede leer la bandera cancela el despliegue" \
  cancela_sin_tocar 'no se pudo leer el modo del correo del portal\.'
parametros ia-proveedor BEDROCK ia-bedrock-modelo-nota "$NOTA" ia-bedrock-modelo-temas "$TEMAS" portal-email-solo-indice true
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "con solo índice y sin clave cancela el despliegue" \
  cancela_sin_tocar 'el modo solo índice exige la clave de correo del portal\.'

echo "== Tokenización interna"
parametros ia-proveedor BEDROCK ia-bedrock-modelo-nota "$NOTA" ia-bedrock-modelo-temas "$TEMAS"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "el modo interno requiere activación explícita" env_contiene 'ARGOS_TOKENIZACION_INTERNA=false'
ARGOS_PRUEBA_PROTECCION_PREVIA=true correr_deploy PARAMETROS="$TMP/ssm"
proteccion_previa_conservada() {
  codigo_es 78 && salida_contiene 'el modo interno activo no puede deshabilitarse' && no_llamo_compose &&
    grep -qx 'caddy del release anterior' "$TMP/app/Caddyfile" &&
    [ "$(cat "$TMP/app/.env")" = 'ARGOS_TOKENIZACION_INTERNA=true' ]
}
afirmar "un parámetro perdido no desactiva un modo interno ya activo" proteccion_previa_conservada
correr_deploy PARAMETROS="$TMP/ssm" SSM_FALLA=tokenizacion-interna
afirmar "si falla SSM no desactiva la protección interna" cancela_sin_tocar 'no se pudo leer /argos/mvp/tokenizacion-interna\.'
printf 'true' > "$TMP/ssm/tokenizacion-interna"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "el modo interno no requiere un cliente Cognito ni una lista de cuentas" env_contiene 'ARGOS_TOKENIZACION_INTERNA=true'
printf 'true' > "$TMP/ssm/tokenizacion-migracion"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "la migración automática se habilita por separado" env_contiene 'ARGOS_TOKENIZACION_MIGRACION=true'
printf 'false' > "$TMP/ssm/tokenizacion-interna"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "no inicia una migración sin modo interno" cancela_sin_tocar 'La migración automática requiere tokenización interna'
printf 'invalida' > "$TMP/ssm/tokenizacion-interna"
correr_deploy PARAMETROS="$TMP/ssm"
afirmar "rechaza un modo interno inválido" cancela_sin_tocar 'Configuración inválida de tokenización interna'

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
