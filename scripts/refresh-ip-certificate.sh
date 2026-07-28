#!/usr/bin/env bash
set -euo pipefail

APP_DIR="/home/ec2-user/argos"
CERTBOT_IMAGE="certbot/certbot:v5.4.0@sha256:1dc5b4a99cce916f154c706569baf062600d7dea13e0711e7d7e1461d6230e39"
SOLO_CERTIFICADO="${1:-}"

if [ -z "${PUBLIC_IP:-}" ]; then
  IMDS_TOKEN="$(curl --fail --silent --show-error --request PUT \
    --header 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
    http://169.254.169.254/latest/api/token)"
  PUBLIC_IP="$(curl --fail --silent --show-error \
    --header "X-aws-ec2-metadata-token: $IMDS_TOKEN" \
    http://169.254.169.254/latest/meta-data/public-ipv4)"
fi

mkdir -p "$APP_DIR/certbot"
GATEWAY_EXISTE="false"
if docker inspect argos-gateway >/dev/null 2>&1; then
  GATEWAY_EXISTE="true"
  docker stop --time 20 argos-gateway >/dev/null || true
fi

reiniciar_gateway() {
  if [ "$GATEWAY_EXISTE" = "true" ] && [ "$SOLO_CERTIFICADO" != "--certificate-only" ]; then
    docker start argos-gateway >/dev/null || true
  fi
}
trap reiniciar_gateway EXIT

docker run --rm \
  --publish 80:80 \
  --volume "$APP_DIR/certbot:/etc/letsencrypt" \
  "$CERTBOT_IMAGE" certonly \
  --standalone \
  --non-interactive \
  --agree-tos \
  --register-unsafely-without-email \
  --preferred-profile shortlived \
  --ip-address "$PUBLIC_IP" \
  --cert-name "$PUBLIC_IP" \
  --keep-until-expiring

trap - EXIT
reiniciar_gateway
