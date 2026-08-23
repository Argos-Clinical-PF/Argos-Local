#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PARAM_PREFIX="/argos/mvp"
APP_DIR="/home/ec2-user/argos"

: "${BACKEND_TAG:?BACKEND_TAG es obligatorio}"
: "${FRONTEND_TAG:?FRONTEND_TAG es obligatorio}"
: "${TRANSCRIPCION_TAG:?TRANSCRIPCION_TAG es obligatorio}"
: "${EMOCIONES_TAG:?EMOCIONES_TAG es obligatorio}"

get_parameter() {
  aws ssm get-parameter \
    --region "$REGION" \
    --name "$PARAM_PREFIX/$1" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text
}

get_parameter_optional() {
  aws ssm get-parameter \
    --region "$REGION" \
    --name "$PARAM_PREFIX/$1" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text 2>/dev/null || true
}

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

mkdir -p "$APP_DIR"
cd "$APP_DIR"

IMDS_TOKEN="$(curl --fail --silent --show-error --request PUT \
  --header 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
  http://169.254.169.254/latest/api/token)"
PUBLIC_IP="$(curl --fail --silent --show-error \
  --header "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
  http://169.254.169.254/latest/meta-data/public-ipv4)"

DIARIZACION_ENABLED="$(get_parameter_optional diarizacion-enabled)"
DIARIZACION_ENABLED="${DIARIZACION_ENABLED:-false}"
ESPERA_ASIGNACION_HORAS="$(get_parameter_optional espera-asignacion-horas)"
ESPERA_ASIGNACION_HORAS="${ESPERA_ASIGNACION_HORAS:-24}"

DEMO_GPU="$(get_parameter_optional demo-gpu)"
DEMO_GPU="${DEMO_GPU:-false}"
if [ "$DEMO_GPU" = "true" ]; then
  if ! command -v nvidia-smi >/dev/null 2>&1 || ! nvidia-smi >/dev/null 2>&1; then
    echo "DEMO_GPU=true pero nvidia-smi no esta disponible. Revisar cuota/AMI/runtime NVIDIA."
    exit 1
  fi
  WHISPER_MODEL_VALUE="$(get_parameter_optional whisper-model-gpu)"
  WHISPER_MODEL_VALUE="${WHISPER_MODEL_VALUE:-medium}"
  WHISPER_DEVICE_VALUE="cuda"
  WHISPER_COMPUTE_VALUE="float16"
else
  WHISPER_MODEL_VALUE="$(get_parameter whisper-model)"
  WHISPER_DEVICE_VALUE="cpu"
  WHISPER_COMPUTE_VALUE="int8"
fi

umask 077
{
  printf 'ECR_REGISTRY=%s\n' "$ECR_REGISTRY"
  printf 'BACKEND_TAG=%s\n' "$BACKEND_TAG"
  printf 'FRONTEND_TAG=%s\n' "$FRONTEND_TAG"
  printf 'TRANSCRIPCION_TAG=%s\n' "$TRANSCRIPCION_TAG"
  printf 'EMOCIONES_TAG=%s\n' "$EMOCIONES_TAG"
  PUBLIC_BASE_URL="$(get_parameter public-base-url)"
  ORIGIN_BASE_URL="$(get_parameter_optional origin-base-url)"
  ORIGIN_BASE_URL="${ORIGIN_BASE_URL:-$PUBLIC_BASE_URL}"
  if [ "$ORIGIN_BASE_URL" = "https://$PUBLIC_IP" ]; then
    ORIGIN_BASE_URL="https://${PUBLIC_IP//./-}.sslip.io"
  fi
  printf 'PUBLIC_BASE_URL=%s\n' "$PUBLIC_BASE_URL"
  printf 'PUBLIC_HOST=%s\n' "${ORIGIN_BASE_URL#https://}"
  printf 'PUBLIC_IP=%s\n' "$PUBLIC_IP"
  if [ "$ORIGIN_BASE_URL" = "$PUBLIC_BASE_URL" ]; then
    printf 'CORS_ALLOWED_ORIGINS=%s,https://%s\n' "$PUBLIC_BASE_URL" "$PUBLIC_IP"
  else
    printf 'CORS_ALLOWED_ORIGINS=%s,%s,https://%s\n' \
      "$PUBLIC_BASE_URL" "$ORIGIN_BASE_URL" "$PUBLIC_IP"
  fi
  printf 'POSTGRES_DB=argos_clinical\n'
  printf 'POSTGRES_USER=argos_app\n'
  printf 'POSTGRES_PASSWORD=%s\n' "$(get_parameter postgres-password)"
  printf 'JWT_SECRET=%s\n' "$(get_parameter jwt-secret)"
  printf 'MAIL_USERNAME=%s\n' "$(get_parameter mail-username)"
  printf 'MAIL_PASSWORD=%s\n' "$(get_parameter mail-password)"
  printf 'MAIL_FROM=%s\n' "$(get_parameter mail-username)"
  printf 'WHISPER_MODEL=%s\n' "$WHISPER_MODEL_VALUE"
  printf 'WHISPER_DEVICE=%s\n' "$WHISPER_DEVICE_VALUE"
  printf 'WHISPER_COMPUTE_TYPE=%s\n' "$WHISPER_COMPUTE_VALUE"
  printf 'WHISPER_IDIOMA=es\n'
  printf 'WHISPER_BEAM_SIZE=3\n'
  printf 'WHISPER_REFINEMENT_BEAM_SIZE=5\n'
  printf 'WHISPER_HOTWORDS=\n'
  printf 'WHISPER_MAX_REFINEMENT_AUDIO_BYTES=134217728\n'
  printf 'WHISPER_CPU_THREADS=4\n'
  printf 'WHISPER_NUM_WORKERS=2\n'
  printf 'WHISPER_MAX_CONCURRENT_INFERENCES=2\n'
  printf 'WHISPER_VAD_MIN_SILENCE_MS=250\n'
  # Nota clinica (Epica 5) y cifrado en reposo (ADR-007). Si el parametro no existe,
  # se escribe vacio: el backend degrada con claridad (503 IA / sin cifrado) sin romper el deploy.
  printf 'ANTHROPIC_API_KEY=%s\n' "$(get_parameter anthropic-api-key 2>/dev/null || true)"
  printf 'ANTHROPIC_MODEL=claude-sonnet-5\n'
  printf 'ENCRYPTION_KEY=%s\n' "$(get_parameter encryption-key 2>/dev/null || true)"
  # Back Office: credenciales del primer ADMIN_PLATAFORMA. Se aplican una sola vez, cuando la
  # tabla administradores esta vacia (AdminSeedRunner). Si el parametro no existe en SSM, se
  # escribe vacio y el seed se omite con un WARN: nunca hay credenciales por defecto conocidas.
  printf 'ADMIN_SEED_EMAIL=%s\n' "$(get_parameter_optional admin-seed-email)"
  printf 'ADMIN_SEED_PASSWORD=%s\n' "$(get_parameter_optional admin-seed-password)"
  printf 'AWS_REGION=%s\n' "$REGION"
  printf 'RECORDINGS_BUCKET=argos-mvp-grabaciones-%s\n' "$ACCOUNT_ID"
  printf 'RECORDINGS_KMS_KEY_ID=alias/aws/s3\n'
  printf 'RECORDINGS_MAX_BYTES=2147483648\n'
  printf 'PROCESSING_AUDIO_ENABLED=true\n'
  printf 'PROCESSING_AUDIO_MAX_RETENTION_HOURS=2\n'
  printf 'PROCESSING_AUDIO_MAX_BYTES=134217728\n'
  printf 'TRANSCRIPCION_REALTIME_TIMEOUT_SECONDS=20\n'
  printf 'TRANSCRIPCION_REALTIME_RETRIES=3\n'
  printf 'TRANSCRIPCION_REALTIME_BACKOFF_MS=1000\n'
  printf 'TRANSCRIPCION_REFINEMENT_TIMEOUT_MINUTES=120\n'
  printf 'EMOCIONES_REQUIRE_FACE_TRACKING=true\n'
  # ARGOS-110 (ADR-026). Sale de SSM y no de una variable de entorno porque el workflow de deploy
  # invoca este script con una lista fija de variables -solo los tags y la region-, asi que una
  # variable de entorno nunca llegaria y la bandera quedaria clavada en false.
  #
  # Mismo patron que demo-gpu. Encender sin tocar codigo ni workflow:
  #   aws ssm put-parameter --name /argos/mvp/diarizacion-enabled --value true --type String --overwrite
  # y volver a desplegar. Este .env se regenera entero en cada deploy, asi que editarlo a mano en la
  # instancia no sobrevive al siguiente.
  printf 'ARGOS_DIARIZACION_ENABLED=%s\n' "$DIARIZACION_ENABLED"
  printf 'ARGOS_ESPERA_ASIGNACION_HORAS=%s\n' "$ESPERA_ASIGNACION_HORAS"
} > .env

COMPOSE_FILES=(-f docker-compose.prod.yml)
if [ "$DEMO_GPU" = "true" ]; then
  COMPOSE_FILES+=(-f docker-compose.gpu.yml)
fi

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

# Guard de espacio: el disco de 30 GiB ya se lleno una vez a mitad de un pull (incidente
# 2026-08-01, "no space left on device" extrayendo una capa de opencv). Mejor abortar
# temprano con un mensaje claro que dejar el compose a medio extraer.
DISPONIBLE_KB=$(df --output=avail / | tail -1)
if [ "$DISPONIBLE_KB" -lt 5242880 ]; then
  echo "Espacio en disco insuficiente para el deploy ($((DISPONIBLE_KB / 1024)) MiB libres, se requieren al menos 5120 MiB). Abortando antes del pull."
  exit 1
fi

docker compose "${COMPOSE_FILES[@]}" --env-file .env pull
docker logout "$ECR_REGISTRY" >/dev/null
# En una unica EC2 el reemplazo concurrente puede dejar referencias a contenedores
# ya eliminados. Down preserva los volumenes y vuelve el release determinista.
docker compose "${COMPOSE_FILES[@]}" --env-file .env down --remove-orphans --timeout 30
PUBLIC_IP="$PUBLIC_IP" "$APP_DIR/refresh-ip-certificate.sh" --certificate-only
docker compose "${COMPOSE_FILES[@]}" --env-file .env up -d --remove-orphans
docker image prune -f || true

for intento in $(seq 1 72); do
  if docker compose "${COMPOSE_FILES[@]}" --env-file .env \
    exec -T backend wget -qO- http://localhost:8080/api/health >/dev/null 2>&1; then
    docker compose "${COMPOSE_FILES[@]}" --env-file .env ps
    exit 0
  fi
  echo "Esperando healthcheck del MVP ($intento/72)..."
  sleep 10
done

docker compose "${COMPOSE_FILES[@]}" --env-file .env ps
docker compose "${COMPOSE_FILES[@]}" --env-file .env logs --tail=100
exit 1
