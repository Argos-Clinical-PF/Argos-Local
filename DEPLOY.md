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
- `Operate MVP`: iniciar, detener o consultar el estado de la instancia.
- `Release MVP`: workflow reutilizable por los servicios, con manifiesto y rollback.

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
