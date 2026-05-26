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
  Argos-Documentacion/
  Argos-ModeloDatos/
```

En el entorno local actual del proyecto, esa estructura puede estar dentro de una carpeta contenedora como `02_argos_repo/`. Lo importante es que `Argos-Local`, `Argos-Backend` y `Argos-Frontend` sean hermanos.

## Clonar repos

Desde la carpeta donde quieras trabajar con ARGOS:

```bash
git clone https://github.com/Argos-Clinical-PF/Argos-Local.git
git clone https://github.com/Argos-Clinical-PF/Argos-Backend.git
git clone https://github.com/Argos-Clinical-PF/Argos-Frontend.git
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
- PostgreSQL: localhost:5432

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

- Backend: `../Argos-Backend`
- Frontend: `../Argos-Frontend`

Por eso `Argos-Local` debe mantenerse como carpeta hermana de ambos repos.

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
