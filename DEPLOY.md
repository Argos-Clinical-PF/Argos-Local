# Deploy del MVP de ARGOS en AWS

## Arquitectura

```text
GitHub Actions (OIDC) -> ECR -> SSM -> EC2 t3.medium
Usuario -> HTTPS sslip.io -> EIP -> Caddy -> Nginx frontend -> backend -> PostgreSQL
                                                       \-> servicio Whisper
```

- No requiere dominio comprado, ALB, SSH ni credenciales AWS guardadas en GitHub.
- `sslip.io` resuelve gratuitamente un hostname basado en la EIP.
- Caddy obtiene y renueva automáticamente un certificado público y exige TLS 1.3.
- PostgreSQL, backend y transcripción no publican puertos al exterior.
- La EC2 configura 2 GB de swap para absorber picos puntuales de Whisper.
- El despliegue automático ocurre al integrar cambios en `main`.

Esta arquitectura es para demostración del MVP y no debe procesar datos clínicos
reales hasta completar la revisión integral de privacidad y seguridad.

## Infraestructura

Desde `Argos-Local/terraform`:

```bash
AWS_PROFILE=argos-facu terraform init
AWS_PROFILE=argos-facu terraform plan
AWS_PROFILE=argos-facu terraform apply
terraform output
```

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
- `Operate MVP`: iniciar, detener, consultar estado o respaldar PostgreSQL.
- `Deploy service image`: workflow reutilizable por los servicios.

## Operación diaria

Para una demo:

1. Ejecutar `Operate MVP` con acción `start`.
2. Esperar el estado saludable y abrir la URL del output de Terraform.
3. Al terminar, ejecutar `Operate MVP` con acción `stop`.

También se puede desplegar manualmente desde `Deploy MVP`, seleccionando los
tags deseados y si la EC2 debe detenerse después de validar.

## Costos

Con la EC2 detenida se mantienen únicamente EBS, EIP, ECR y S3 de bajo uso. No
hay costo fijo de ALB, CloudFront ni dominio. Antes y después de cada demo,
confirmar que la instancia `argos-app` esté en estado `stopped`.

## Recuperación

- Los datos de PostgreSQL persisten en el volumen Docker de la EC2.
- `Operate MVP` permite generar un dump cifrado en el bucket S3 operativo.
- Las imágenes conservan tags inmutables `sha-*` para volver a una versión.
- Para rollback, ejecutar `Deploy MVP` indicando los tags `sha-*` previos.
