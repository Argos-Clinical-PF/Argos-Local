#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
PARAM_PREFIX="/argos/mvp"
APP_DIR="/home/ec2-user/argos"

get_parameter() {
  aws ssm get-parameter \
    --region "$REGION" \
    --name "$PARAM_PREFIX/$1" \
    --with-decryption \
    --query "Parameter.Value" \
    --output text
}

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

mkdir -p "$APP_DIR"
cd "$APP_DIR"

umask 077
{
  printf 'ECR_REGISTRY=%s\n' "$ECR_REGISTRY"
  printf 'BACKEND_TAG=%s\n' "${BACKEND_TAG:-main}"
  printf 'FRONTEND_TAG=%s\n' "${FRONTEND_TAG:-main}"
  printf 'TRANSCRIPCION_TAG=%s\n' "${TRANSCRIPCION_TAG:-main}"
  PUBLIC_BASE_URL="$(get_parameter public-base-url)"
  printf 'PUBLIC_BASE_URL=%s\n' "$PUBLIC_BASE_URL"
  printf 'PUBLIC_HOST=%s\n' "${PUBLIC_BASE_URL#https://}"
  printf 'POSTGRES_DB=argos_clinical\n'
  printf 'POSTGRES_USER=argos_app\n'
  printf 'POSTGRES_PASSWORD=%s\n' "$(get_parameter postgres-password)"
  printf 'JWT_SECRET=%s\n' "$(get_parameter jwt-secret)"
  printf 'MAIL_USERNAME=%s\n' "$(get_parameter mail-username)"
  printf 'MAIL_PASSWORD=%s\n' "$(get_parameter mail-password)"
  printf 'MAIL_FROM=%s\n' "$(get_parameter mail-username)"
  printf 'WHISPER_MODEL=%s\n' "$(get_parameter whisper-model)"
  printf 'WHISPER_DEVICE=cpu\n'
  printf 'WHISPER_COMPUTE_TYPE=int8\n'
  printf 'WHISPER_IDIOMA=es\n'
  # Nota clinica (Epica 5) y cifrado en reposo (ADR-007). Si el parametro no existe,
  # se escribe vacio: el backend degrada con claridad (503 IA / sin cifrado) sin romper el deploy.
  printf 'ANTHROPIC_API_KEY=%s\n' "$(get_parameter anthropic-api-key 2>/dev/null || true)"
  printf 'ANTHROPIC_MODEL=claude-sonnet-4-6\n'
  printf 'ENCRYPTION_KEY=%s\n' "$(get_parameter encryption-key 2>/dev/null || true)"
} > .env

aws ecr get-login-password --region "$REGION" \
  | docker login --username AWS --password-stdin "$ECR_REGISTRY"

docker compose -f docker-compose.prod.yml --env-file .env pull
docker logout "$ECR_REGISTRY" >/dev/null
docker compose -f docker-compose.prod.yml --env-file .env up -d --remove-orphans
docker image prune -f

for intento in $(seq 1 72); do
  if docker compose -f docker-compose.prod.yml --env-file .env \
    exec -T backend wget -qO- http://localhost:8080/api/health >/dev/null 2>&1; then
    docker compose -f docker-compose.prod.yml --env-file .env ps
    exit 0
  fi
  echo "Esperando healthcheck del MVP ($intento/72)..."
  sleep 10
done

docker compose -f docker-compose.prod.yml --env-file .env ps
docker compose -f docker-compose.prod.yml --env-file .env logs --tail=100
exit 1
