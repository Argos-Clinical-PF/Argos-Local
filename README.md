# Argos-Local

Orquestador local de ARGOS Clinical para levantar la aplicacion completa con Docker Compose.

Este repositorio no contiene codigo de backend ni frontend. Solo define la configuracion local para ejecutar los servicios desde repos separados.

## Estructura esperada

Ubicar los repos como carpetas hermanas:

```text
ARGOS/
  Argos-Local/
  Argos-Backend/
  Argos-Frontend/
  Argos-Entrenamiento/
  Argos-Documentacion/
  Argos-ModeloDatos/
```

En el entorno local actual del proyecto, esa estructura puede estar dentro de una carpeta contenedora como `02_argos_repo/`. Lo importante es que `Argos-Local`, `Argos-Backend`, `Argos-Frontend` y `Argos-Entrenamiento` sean hermanos: el compose construye desde rutas relativas y sin `Argos-Entrenamiento` no levantan los servicios de IA.

## Clonar repos

Desde la carpeta donde quieras trabajar con ARGOS:

```bash
git clone https://github.com/Argos-Clinical-PF/Argos-Local.git
git clone https://github.com/Argos-Clinical-PF/Argos-Backend.git
git clone https://github.com/Argos-Clinical-PF/Argos-Frontend.git
git clone https://github.com/Argos-Clinical-PF/Argos-Entrenamiento.git
git clone https://github.com/Argos-Clinical-PF/Argos-Documentacion.git
git clone https://github.com/Argos-Clinical-PF/Argos-ModeloDatos.git
```

## Configurar variables locales

Crear el `.env` local a partir del ejemplo:

```bash
cd Argos-Local
cp .env.example .env
```

Editar `.env` y completar, si se quiere probar envio real de email:

```env
MAIL_PASSWORD=COMPLETAR_APP_PASSWORD_DE_GMAIL
```

No commitear `.env`: puede contener contrasenas o secretos locales.

En el `docker-compose.yml`, el servicio `backend` debe cargar ese archivo:

```yaml
env_file:
  - .env
```
## Levantar la app

Desde `Argos-Local`:

```bash
docker compose up -d --build
```

Servicios expuestos:

- Frontend: http://localhost:5173
- Backend: http://localhost:8080
- Swagger UI: http://localhost:8080/swagger-ui.html
- Health backend: http://localhost:8080/api/health
- Transcripcion: http://localhost:9000/health
- Emociones: http://localhost:9010/health
- PostgreSQL: localhost:5432

> **La primera build de `transcripcion` tarda.** La imagen construye el encoder de audio
> adaptado en una etapa aparte —instala torch, fusiona LoRA, convierte a CTranslate2 y verifica
> el resultado— porque el modelo pesa 237 MB y no puede vivir en Git. Las builds siguientes usan
> cache.

## Comandos principales

Levantar o reconstruir todo:

```bash
docker compose up -d --build
```

Ver logs de todos los servicios:

```bash
docker compose logs -f
```

Ver logs por servicio:

```bash
docker compose logs -f backend
docker compose logs -f frontend
docker compose logs -f postgres
```

Ver estado:

```bash
docker compose ps
```

Detener servicios sin borrar datos:

```bash
docker compose down
```

Detener servicios y borrar la base local:

```bash
docker compose down -v
```

## Como construye los servicios

`docker-compose.yml` usa rutas relativas:

| Servicio | Contexto | Dockerfile |
|---|---|---|
| Backend | `../Argos-Backend` | por defecto, `target: development` |
| Frontend | `../Argos-Frontend` | por defecto, `target: development` |
| Transcripcion | `../Argos-Entrenamiento` | `servicio-transcripcion/Dockerfile`, `target: production` |
| Emociones | `../Argos-Entrenamiento` | `servicio-emociones/Dockerfile` |

Por eso `Argos-Local` debe mantenerse como carpeta hermana de los tres repos de codigo.

**El contexto de los servicios de IA es la raiz de `Argos-Entrenamiento`, no la carpeta del
servicio.** La etapa que construye el encoder emocional necesita `angel/` —el checkpoint y los
scripts de export y verificacion—, que vive fuera de `servicio-transcripcion/`.

## Los dos compose

| Archivo | Para que |
|---|---|
| `docker-compose.yml` | Entorno local. Construye las imagenes desde los repos hermanos |
| `docker-compose.prod.yml` | **El que usa el deploy.** Consume imagenes ya publicadas en ECR por tag |

Un cambio de configuracion que solo toque `docker-compose.yml` **no llega a produccion**.

### La fusion emocional viene apagada en local, encendida en produccion

| Variable | Local | Produccion |
|---|---|---|
| `WHISPER_EMBEDDING_MODEL` | vacio | `/modelos/whisper-argos-ser-int8` |
| `EMOCIONES_FUSION_ARTEFACTO` | v3 | v3 |
| `ARGOS_FUSION_INTERMEDIA_ENABLED` | `false` | `true` |

Para encenderla en local alcanza con copiar `.env.example`, que ya trae las tres con el valor de
produccion, y levantar de nuevo.

**Las tres van juntas.** La fusion v3 declara con que encoder fue entrenada y **rechaza con 400**
los embeddings de otro, asi que encender una sola falla de forma ruidosa —que es lo que se busca—
en vez de devolver emociones plausibles calculadas sobre un espacio latente equivocado.

Para revertir: `ARGOS_FUSION_INTERMEDIA_ENABLED=false` y reiniciar el backend. Segundos, sin
redesplegar imagenes.

## Notas de configuracion

- `VITE_API_BASE_URL` debe apuntar al origen del backend, por ejemplo `http://localhost:8080`.
- No agregar `/api` a `VITE_API_BASE_URL`, porque el frontend ya usa rutas como `/api/auth/register`.
- `JWT_SECRET` debe tener al menos 32 bytes para HS256.
- Para Gmail se recomienda usar una App Password. En produccion puede convenir migrar a un proveedor transaccional como Brevo, SendGrid, Amazon SES o Mailgun.


## Persistencia de la base de datos

PostgreSQL guarda sus datos en un volumen Docker llamado `argos-postgres-data`.

Esto permite que la base de datos conserve su información aunque se detengan o reinicien los contenedores.

Comandos seguros:

```bash
docker compose down
docker compose stop
docker compose up -d
```

Estos comandos no eliminan la base de datos.

Comando peligroso:

```bash
docker compose down -v
```

Este comando elimina los volúmenes asociados al proyecto y puede borrar la base de datos local.

También evitar borrar manualmente el volumen `argos-postgres-data` desde Docker Desktop o mediante comandos como:

```bash
docker volume rm argos-postgres-data
docker volume prune
```

Para desarrollo local esta configuración es suficiente, pero si se necesita conservar información importante, se recomienda hacer backups/exportaciones de la base de datos.

Ejemplo de exportación manual:

```bash
docker exec -t argos-postgres pg_dump -U argos_app argos_clinical > backup.sql
```

En resumen: mientras no se use `docker compose down -v` ni se elimine manualmente el volumen, la base de datos debería persistir correctamente.
