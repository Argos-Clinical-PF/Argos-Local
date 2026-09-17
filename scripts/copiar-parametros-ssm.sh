#!/usr/bin/env bash
# Copia /argos/mvp/* de la cuenta vieja a la nueva. Los valores nunca se imprimen:
# viajan de un `get-parameter` a un `put-parameter` dentro de la misma variable.
set -euo pipefail
ORIGEN=${1:-argos-facu}
DESTINO=${2:-argos-nuevos}
for nombre in $(aws ssm get-parameters-by-path --path /argos/mvp --recursive \
      --profile "$ORIGEN" --query 'Parameters[].Name' --output text); do
  tipo=$(aws ssm get-parameter --name "$nombre" --profile "$ORIGEN" \
      --query 'Parameter.Type' --output text)
  valor=$(aws ssm get-parameter --name "$nombre" --with-decryption --profile "$ORIGEN" \
      --query 'Parameter.Value' --output text)
  aws ssm put-parameter --name "$nombre" --type "$tipo" --value "$valor" --overwrite \
      --profile "$DESTINO" >/dev/null
  echo "copiado $nombre ($tipo, ${#valor} caracteres)"
  unset valor
done
