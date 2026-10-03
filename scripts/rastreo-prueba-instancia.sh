#!/usr/bin/env bash
# Stack de prueba del rastreo por cuadros junto a producción, en la instancia (ADR-038): backend y
# servicio de emociones de las imágenes indicadas, con una base propia y la bandera encendida, y la
# transcripción real (enrutador de modelos). El backend escucha solo en 127.0.0.1:8081; se llega con
# un túnel de Session Manager. Producción y sus datos no se tocan. Ver DEPLOY.md.
#
# Uso (como root, por SSM):  rastreo-prueba-instancia.sh arriba <tag-backend> <tag-emociones>
#                            rastreo-prueba-instancia.sh abajo  <tag-backend> <tag-emociones>
set -euo pipefail

accion=${1:?arriba o abajo}
tag_backend=${2:?tag del backend}
tag_emociones=${3:?tag de emociones}
REGISTRO=616322963974.dkr.ecr.us-east-1.amazonaws.com
BACKEND="$REGISTRO/argos-backend:$tag_backend"
EMOCIONES="$REGISTRO/argos-emociones:$tag_emociones"

if [ "$accion" = abajo ]; then
  docker rm -f argos-prueba-backend argos-prueba-emociones argos-prueba-postgres >/dev/null 2>&1 || true
  docker volume rm argos-prueba-datos >/dev/null 2>&1 || true
  docker rmi "$BACKEND" "$EMOCIONES" >/dev/null 2>&1 || true
  exit 0
fi

aws ecr get-login-password --region us-east-1 | docker login -u AWS --password-stdin "$REGISTRO" >/dev/null 2>&1
docker pull -q "$BACKEND" >/dev/null
docker pull -q "$EMOCIONES" >/dev/null
red=$(docker inspect argos-backend --format '{{range $k, $v := .NetworkSettings.Networks}}{{$k}} {{end}}' | awk '{print $1}')
clave_db=$(openssl rand -hex 24)
clave_jwt=$(openssl rand -hex 32)
docker volume create argos-prueba-datos >/dev/null
docker run -d --name argos-prueba-postgres --network "$red" -e POSTGRES_DB=argos_prueba -e POSTGRES_USER=argos_prueba \
  -e POSTGRES_PASSWORD="$clave_db" -v argos-prueba-datos:/var/lib/postgresql/data postgres:16-alpine >/dev/null
# Los mismos topes de CPU que el servicio de producción.
docker run -d --name argos-prueba-emociones --network "$red" --cpus 1.5 --cpu-shares 256 \
  -e EMOCIONES_MODEL_ID=emotiefflib-enet-b0-8-va-mtl -e EMOCIONES_MOCK=false -e EMOCIONES_STRICT_LOAD=true \
  -e EMOCIONES_REQUIRE_FACE_TRACKING=true -e EMOCIONES_ORT_HILOS=1 -e EMOCIONES_OPENCV_HILOS=1 -e OMP_NUM_THREADS=1 \
  "$EMOCIONES" >/dev/null
for _ in $(seq 1 30); do docker exec argos-prueba-postgres pg_isready -U argos_prueba -d argos_prueba >/dev/null 2>&1 && break; sleep 2; done
docker run -d --name argos-prueba-backend --network "$red" -p 127.0.0.1:8081:8080 \
  -e DB_URL=jdbc:postgresql://argos-prueba-postgres:5432/argos_prueba -e DB_USERNAME=argos_prueba -e DB_PASSWORD="$clave_db" \
  -e DB_MIGRATIONS_ENABLED=true -e JWT_SECRET="$clave_jwt" -e APP_DEMO_SEED_ENABLED=true \
  -e EMOCIONES_SERVICE_URL=http://argos-prueba-emociones:9010 -e EMOCIONES_ENABLED=true \
  -e TRANSCRIPCION_SERVICE_URL=http://enrutador-modelos:9100 -e ARGOS_EMOCIONES_RASTREO_HABILITADO=true \
  -e RECORDINGS_ENABLED=false -e PROCESSING_AUDIO_ENABLED=false -e AWS_EC2_METADATA_DISABLED=true \
  -e MAIL_HOST=localhost -e MAIL_PORT=1025 -e MAIL_SMTP_AUTH=false -e MAIL_SMTP_STARTTLS_ENABLE=false \
  -e CORS_ALLOWED_ORIGINS=http://localhost:5182 -e APP_PUBLIC_BASE_URL=http://localhost:5182 \
  -e JAVA_TOOL_OPTIONS="-Xmx768m -XX:+UseG1GC" "$BACKEND" >/dev/null
for _ in $(seq 1 60); do curl -fs http://127.0.0.1:8081/api/health >/dev/null 2>&1 && break; sleep 3; done
curl -fs http://127.0.0.1:8081/api/health >/dev/null
# La cuenta demo del seed está en TRIAL: en esta base descartable se suben sus límites para la carga.
docker exec argos-prueba-postgres psql -U argos_prueba -d argos_prueba -qc \
  "UPDATE planes SET limite_pacientes_activos = 1000, limite_minutos_transcripcion_mes = 100000 WHERE codigo = 'TRIAL'"
echo "stack de prueba listo en 127.0.0.1:8081"
