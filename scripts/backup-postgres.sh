#!/usr/bin/env bash
set -euo pipefail

REGION="${AWS_REGION:-us-east-1}"
APP_DIR="/home/ec2-user/argos"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="argos-mvp-operacion-${ACCOUNT_ID}"
TIMESTAMP="$(date -u +%Y%m%dT%H%M%SZ)"
BACKUP="/tmp/argos-${TIMESTAMP}.sql.gz"

cd "$APP_DIR"

if ! docker ps --format '{{.Names}}' | grep -qx argos-postgres; then
  echo "PostgreSQL no esta ejecutandose; no se genera backup."
  exit 0
fi

docker exec argos-postgres pg_dump -U argos_app argos_clinical | gzip > "$BACKUP"
aws s3 cp "$BACKUP" "s3://${BUCKET}/backups/${TIMESTAMP}.sql.gz" --region "$REGION"
rm -f "$BACKUP"
