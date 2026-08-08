# Deploy del MVP de ARGOS en AWS

## Arquitectura

```text
GitHub Actions (OIDC) -> ECR -> SSM -> EC2 c7i.2xlarge
Usuario -> HTTPS sslip.io -> EIP -> Caddy -> Nginx frontend -> backend -> PostgreSQL
                                                       \-> Whisper + emociones
```

- No requiere dominio comprado, ALB, SSH ni credenciales AWS guardadas en GitHub.
- `sslip.io` resuelve gratuitamente un hostname basado en la EIP.
- Caddy obtiene y renueva automáticamente un certificado público y exige TLS 1.3.
- PostgreSQL, backend y transcripción no publican puertos al exterior.
- La instancia compute-optimized aporta 8 vCPU sostenidas para la inferencia CPU
  y permanece detenida fuera de demos.
- El despliegue automático ocurre al integrar cambios en `main`.

Esta arquitectura es para demostración del MVP y no debe procesar datos clínicos
reales hasta completar la revisión integral de privacidad y seguridad.

## Infraestructura

Desde `Argos-Local/terraform`:

```bash
export AWS_PROFILE=argos-<tu-nombre>   # cada integrante tiene el suyo
terraform init
terraform plan
terraform apply
terraform output
```

El nombre del perfil **no se hardcodea**: cada integrante configura el suyo y lo declara con
`AWS_PROFILE`. Si falla con `Unable to locate credentials`, listar los disponibles con
`aws configure list-profiles`.

Terraform administra EC2/EIP, ECR, S3 operativo, SSM, IAM y el rol
OIDC `argos-github-actions`.

## Parámetros SSM

Los secretos se almacenan cifrados en Parameter Store bajo `/argos/mvp/`:

```text
public-base-url
postgres-password
jwt-secret
mail-username
mail-password
whisper-model
```

Nunca guardar estos valores en GitHub, archivos versionados ni salidas de CI.

## Automatización

Cada repositorio de servicio contiene `.github/workflows/ci-cd.yml`:

- Pull request a `develop` o `main`: valida código e imagen.
- Push a `main`: publica `main` y `sha-<commit>` en ECR, llama al workflow
  reutilizable de `Argos-Local`, despliega y vuelve a detener la EC2.

`Argos-Local` contiene:

- `Deploy MVP`: despliegue completo manual o ante cambios del Compose.
- `Operate MVP`: iniciar, detener o consultar el estado de la instancia.
- `Release MVP`: workflow reutilizable por los servicios, con manifiesto y rollback.

## El Compose que manda es `docker-compose.prod.yml`

El deploy sube ese archivo a S3 y la EC2 lo ejecuta contra las imágenes de ECR. **Un cambio de
configuración que solo toque `docker-compose.yml` no llega a producción.**

Los defaults de producción se resuelven en tres niveles, de menor a mayor prioridad:

1. el default `${VAR:-valor}` del propio `docker-compose.prod.yml`;
2. un `.env` en el disco de la instancia, si existe;
3. las variables que inyecta el workflow.

## Encoder de audio adaptado (ARGOS-169 / ADR-025)

Desde el 2026-08-06 `transcripcion` sirve **dos** modelos: `small` de fábrica para
`/transcribir` y `whisper-small-argos-ser-int8` **solo** para `/embed`.

El binario no está en Git —pesa 237 MB y GitHub corta en 100 MB—, así que **la imagen lo
construye** desde un checkpoint de 8 MB y **verifica** que reproduce el modelo evaluado antes de
seguir. Si no reproduce, la build falla y no se publica nada. La imagen pasa de 353 a 554 MB.

Tres variables encienden la ruta y **van juntas**:

| Servicio | Variable | Valor en producción |
|---|---|---|
| transcripcion | `WHISPER_EMBEDDING_MODEL` | `/modelos/whisper-argos-ser-int8` |
| emociones | `EMOCIONES_FUSION_ARTEFACTO` | `…/fusion-intermedia-v3.npz` |
| backend | `ARGOS_FUSION_INTERMEDIA_ENABLED` | `true` |

**Orden de despliegue:** transcripción primero —expone `/embed` con el encoder nuevo y, como
nadie lo consume todavía, no cambia nada—, después emociones con la v3, y por último el backend.

**Reversión:** `ARGOS_FUSION_INTERMEDIA_ENABLED=false` y reiniciar el backend. Segundos, sin
redesplegar imágenes.

La fusión v3 declara con qué encoder fue entrenada y **rechaza con 400** los embeddings de otro,
así que desplegar una pieza sin las otras falla de forma ruidosa en vez de producir emociones
plausibles sobre un espacio latente equivocado.

## Operación diaria

Para una demo:

1. Verificar que no haya un workflow `Release MVP` en ejecución.
2. Ejecutar `Operate MVP` con acción `start` desde GitHub Actions o por CLI:

   ```bash
   gh workflow run operate.yml -f action=start
   gh run list --workflow operate.yml --limit 1
   ```

3. Esperar que el workflow finalice. El arranque de EC2, Docker y los modelos
   puede tardar entre cuatro y ocho minutos; `running` no significa todavía que
   la aplicación esté saludable.
4. Abrir `https://32-193-249-170.sslip.io` solamente después del smoke test.
5. Al terminar, ejecutar `Operate MVP` con acción `stop`.

   ```bash
   gh workflow run operate.yml -f action=stop
   ```

La consola de EC2 también puede iniciar la instancia, pero no espera el health
de la aplicación. Los workflows de release la detienen siempre al finalizar,
incluso si el despliegue falla.

También se puede desplegar manualmente desde `Deploy MVP`, seleccionando los
tags deseados y si la EC2 debe detenerse después de validar.

## Costos

Con la EC2 detenida se mantienen únicamente EBS, EIP, ECR y S3 de bajo uso. No
hay costo fijo de ALB, CloudFront ni dominio. Antes y después de cada demo,
confirmar que la instancia `argos-app` esté en estado `stopped`.

## Recuperación

- Los datos de PostgreSQL persisten en el volumen Docker de la EC2.
- Las imágenes conservan tags inmutables `sha-*` para volver a una versión.
- Para rollback, ejecutar `Deploy MVP` indicando los tags `sha-*` previos.
