#!/bin/bash
# User data del host de inferencia GPU (ADR-037) sobre la DLAMI «Base OSS Nvidia Driver GPU AMI
# (Amazon Linux 2023)», que ya trae driver, Docker y NVIDIA Container Toolkit. Lo renderiza
# Terraform con templatefile (inferencia.tf): sus valores van solo en los heredocs de abajo, y el
# resto del script escribe las variables sin llaves para no chocar con esa sintaxis.
#
# Corre en el primer arranque de cada instancia (el ASG no reinicia instancias: las reemplaza) y es
# idempotente. Todo queda en /var/log/argos-inferencia.log.
set -euo pipefail
exec > >(tee -a /var/log/argos-inferencia.log) 2>&1

log() { echo "$(date -u +%FT%TZ) argos-inferencia: $*" >&2; }
trap 'log "falló la línea $LINENO; la app sigue transcribiendo con su CPU"' ERR

reintentar() {
  local intentos="$1" espera="$2" n=1
  shift 2
  until "$@"; do
    if [ "$n" -ge "$intentos" ]; then
      log "$1 falló $n veces seguidas"
      return 1
    fi
    log "$1 falló ($n/$intentos); se reintenta en $espera s"
    n=$((n + 1))
    sleep "$espera"
  done
}

log "configurando"
cat > /etc/argos-inferencia.env <<'EOS'
REGION=${region}
BUCKET=${bucket}
REPOSITORIO=${repositorio}
ASG=${asg}
APP=${app}
ZONA=${zona}
NOMBRE_DNS=${nombre_dns}
GRUPO_LOGS=${grupo_logs}
EOS
chmod 644 /etc/argos-inferencia.env
# shellcheck source=/dev/null
. /etc/argos-inferencia.env

# Primero el vigía, antes de cualquier paso que pueda fallar: la GPU nunca factura sin la app.
# Baja el ASG a 0 solo con dos lecturas seguidas y exitosas de la API que muestran la app sin
# correr; una lectura fallida reinicia la cuenta en vez de sumar.
cat > /usr/local/bin/argos-inferencia-vigia <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=/dev/null
. /etc/argos-inferencia.env
MARCA=/run/argos-inferencia-vigia
if ! ESTADOS="$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Name,Values=$APP" \
  --query 'Reservations[].Instances[].State.Name' --output text)"; then
  rm -f "$MARCA"
  echo "No se pudo leer el estado de $APP; la lectura no cuenta."
  exit 0
fi
if grep -qwE 'running|pending' <<<"$ESTADOS"; then
  rm -f "$MARCA"
  exit 0
fi
if [ ! -e "$MARCA" ]; then
  touch "$MARCA"
  echo "$APP no está corriendo ($ESTADOS); se confirma en la próxima lectura."
  exit 0
fi
echo "$APP sigue sin correr ($ESTADOS); se baja $ASG a 0."
aws autoscaling set-desired-capacity --region "$REGION" \
  --auto-scaling-group-name "$ASG" --desired-capacity 0
rm -f "$MARCA"
EOS
chmod 700 /usr/local/bin/argos-inferencia-vigia
cat > /etc/systemd/system/argos-inferencia-vigia.service <<'EOS'
[Unit]
Description=ARGOS: baja el host GPU si la app no está corriendo
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/argos-inferencia-vigia
EOS
cat > /etc/systemd/system/argos-inferencia-vigia.timer <<'EOS'
[Unit]
Description=ARGOS: vigía del host GPU cada 5 minutos

[Timer]
OnBootSec=5min
OnUnitActiveSec=5min

[Install]
WantedBy=timers.target
EOS
systemctl daemon-reload
systemctl enable --now argos-inferencia-vigia.timer

# Lo corre también Release MVP por SSM (ver scripts/inferencia-actualizar.sh).
cat > /usr/local/bin/argos-inferencia-actualizar <<'ARGOS_ACTUALIZAR'
${actualizar}
ARGOS_ACTUALIZAR
chmod 700 /usr/local/bin/argos-inferencia-actualizar

systemctl enable --now docker

# Solo el modelo de Whisper se baja en tiempo de ejecución: el encoder de voces y el VAD vienen en
# la imagen. Con la caché de S3 el arranque no depende de Hugging Face.
CACHE=/var/lib/argos/hf-cache
MODELOS="s3://$BUCKET/modelos/huggingface/"
install -d -m 700 "$CACHE"
log "bajando la caché de modelos de $MODELOS"
reintentar 5 10 aws s3 sync "$MODELOS" "$CACHE" --region "$REGION" --only-show-errors
CACHE_VACIA=false
[ -n "$(ls -A "$CACHE")" ] || CACHE_VACIA=true

# El registro apunta acá antes de que el modelo cargue: el enrutador de la app no manda nada
# hasta que /health responda "ok".
TOKEN="$(curl -fsS -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 300' \
  http://169.254.169.254/latest/api/token)"
IP="$(curl -fsS -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/local-ipv4)"
CAMBIO="$(printf '{"Changes":[{"Action":"UPSERT","ResourceRecordSet":{"Name":"%s","Type":"A","TTL":10,"ResourceRecords":[{"Value":"%s"}]}}]}' "$NOMBRE_DNS" "$IP")"
log "$NOMBRE_DNS -> $IP"
reintentar 5 5 aws route53 change-resource-record-sets --region "$REGION" \
  --hosted-zone-id "$ZONA" --change-batch "$CAMBIO" --query ChangeInfo.Status --output text

log "levantando la transcripción"
/usr/local/bin/argos-inferencia-actualizar

# Con el modelo ya cargado la caché está completa. Se suben los snapshots (el symlink resuelto) y
# no los blobs, que son los mismos archivos: Hugging Face los encuentra igual en el próximo arranque.
if [ "$CACHE_VACIA" = "true" ]; then
  log "subiendo la caché de modelos a $MODELOS para los próximos arranques"
  reintentar 3 30 aws s3 sync "$CACHE" "$MODELOS" --region "$REGION" --only-show-errors \
    --exclude '*/blobs/*' --exclude '*/.locks/*' --exclude 'xet/*'
fi
log "listo"
