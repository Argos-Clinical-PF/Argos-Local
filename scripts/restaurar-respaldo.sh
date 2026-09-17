#!/usr/bin/env bash
# Restaura en la cuenta nueva el respaldo tomado de la cuenta vieja.
#
# El backend se detiene durante la restauracion: Flyway y pg_restore no pueden tocar el mismo
# esquema a la vez. El volcado incluye flyway_schema_history, asi que al volver a levantar, el
# backend encuentra la base en la misma version de esquema que tenia el original.
#
# Uso:  ./restaurar-respaldo.sh <ruta-al-dump> [perfil-aws]
set -euo pipefail

DUMP="${1:?Falta la ruta al archivo .dump}"
PERFIL="${2:-argos-nuevos}"
INSTANCIA="$(aws ec2 describe-instances --profile "$PERFIL" \
  --filters "Name=tag:Name,Values=argos-app" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)"
BUCKET="$(aws s3api list-buckets --profile "$PERFIL" \
  --query "Buckets[?starts_with(Name, 'argos-mvp-operacion')].Name | [0]" --output text)"

[ "$INSTANCIA" = "None" ] && { echo "No hay instancia argos-app corriendo en $PERFIL"; exit 1; }
[ "$BUCKET" = "None" ] && { echo "No se encontro el bucket de operacion en $PERFIL"; exit 1; }

echo "Instancia: $INSTANCIA"
echo "Bucket:    $BUCKET"
aws s3 cp "$DUMP" "s3://$BUCKET/respaldo-migracion/restaurar.dump" --profile "$PERFIL"

ID=$(aws ssm send-command --profile "$PERFIL" --instance-ids "$INSTANCIA" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["set -e",
    "cd /home/ec2-user/argos",
    "aws s3 cp s3://'"$BUCKET"'/respaldo-migracion/restaurar.dump /tmp/restaurar.dump",
    "docker compose -f docker-compose.prod.yml stop backend",
    "docker cp /tmp/restaurar.dump argos-postgres:/tmp/restaurar.dump",
    "docker exec argos-postgres pg_restore -U argos_app -d argos_clinical --clean --if-exists --no-owner /tmp/restaurar.dump",
    "docker compose -f docker-compose.prod.yml start backend",
    "docker exec argos-postgres psql -U argos_app -d argos_clinical -tAc \"select count(*) from pacientes\""]' \
  --query 'Command.CommandId' --output text)

for _ in $(seq 1 60); do
  ESTADO=$(aws ssm get-command-invocation --profile "$PERFIL" --command-id "$ID" \
    --instance-id "$INSTANCIA" --query Status --output text 2>/dev/null || echo Pending)
  case "$ESTADO" in Success|Failed|TimedOut|Cancelled) break;; esac
  sleep 5
done

echo "estado=$ESTADO"
aws ssm get-command-invocation --profile "$PERFIL" --command-id "$ID" --instance-id "$INSTANCIA" \
  --query StandardOutputContent --output text
aws ssm get-command-invocation --profile "$PERFIL" --command-id "$ID" --instance-id "$INSTANCIA" \
  --query StandardErrorContent --output text | tail -20
aws s3 rm "s3://$BUCKET/respaldo-migracion/restaurar.dump" --profile "$PERFIL"
