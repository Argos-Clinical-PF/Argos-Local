# Deploy del MVP de ARGOS en AWS

## Arquitectura

```text
GitHub Actions (OIDC) -> ECR -> SSM -> EC2 c7i.2xlarge
Usuario -> HTTPS argosclinical.online -> CloudFront (+ AWS WAF) -> origin.argosclinical.online
        -> EIP -> Caddy -> Nginx frontend -> backend -> PostgreSQL
                                                 \-> Whisper + emociones
```

> **CloudFront está delante de todo desde el 2026-08-06.** `argosclinical.online` no resuelve al
> EC2: resuelve a CloudFront, que reenvía al origen. Un 4xx que no aparezca en los logs del backend
> probablemente lo generó CloudFront o su WAF. Ver
> [«AWS WAF y las rutas de subida»](#aws-waf-y-las-rutas-de-subida) más abajo y
> [ADR-023](../Argos-Documentacion/ADRs/ARGOS_ADR_023_Arquitectura_AWS_y_Dominio.md).

- No requiere ALB, SSH ni credenciales AWS guardadas en GitHub.
- `sslip.io` resuelve gratuitamente un hostname basado en la EIP, y sigue sirviendo como acceso
  directo al origen, sin pasar por CloudFront — útil justamente para descartar al borde cuando algo
  falla.
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

## FER es la única fuente emocional (ADR-027)

El encoder de audio adaptado (ADR-025) y la fusión intermedia (ADR-024) se eliminaron:
`transcripcion` vuelve a servir un solo modelo Whisper (`/transcribir`), y `emociones` solo
expone `/infer/video` — idéntico en sesiones presenciales y virtuales. Ver
[ADR-027](../Argos-Documentacion/ADRs/ARGOS_ADR_027_Eliminacion_de_la_Fusion_Tardia.md), que
deroga ambos ADRs.

## AWS WAF y las rutas de subida

**Síntoma a reconocer:** la app funciona, pero **solo** fallan con `403` el envío de audio, el envío
de frames de video y la subida de foto de perfil. En la sala se ve "análisis facial: modelo no
disponible" y la transcripción no avanza. **En los logs del backend no hay nada**, porque la request
nunca llegó al EC2.

Si eso pasa, el culpable es el WAF de CloudFront, no los modelos. Diagnóstico en un comando —el
tamaño del cuerpo es lo único que cambia entre las dos pruebas:

```bash
head -c 8000  /dev/zero | tr '\0' a > /tmp/chico.bin   # 8 KB  -> debe pasar
head -c 30000 /dev/zero | tr '\0' a > /tmp/grande.bin  # 30 KB -> si da 403, es el WAF
for f in chico grande; do
  printf '%s -> ' "$f"
  curl -s -o /dev/null -w '%{http_code}\n' -X POST \
    https://argosclinical.online/api/waf-probe --data-binary @/tmp/$f.bin
done
```

Un `403` solo en el grande confirma `SizeRestrictions_BODY` del `AWSManagedRulesCommonRuleSet`, que
rechaza cualquier cuerpo mayor a 8.192 bytes. La confirmación en métricas:

```bash
aws cloudwatch get-metric-statistics --namespace AWS/WAFV2 \
  --metric-name BlockedRequests --region us-east-1 \
  --dimensions Name=WebACL,Value=CreatedByCloudFront-8f1a9620 \
               Name=ManagedRuleGroup,Value=AWSManagedRulesCommonRuleSet \
               Name=ManagedRuleGroupRule,Value=SizeRestrictions_BODY \
  --start-time "$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)" \
  --end-time   "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --period 3600 --statistics Sum --output text
```

### Reparación

El WebACL vigente (`CreatedByCloudFront-8f1a9620`, scope `CLOUDFRONT`, siempre `us-east-1`) tiene
**todas** las reglas de los tres grupos administrados en `Count`: observa y publica métricas, no
bloquea. Si alguien lo recrea desde el asistente de CloudFront, vuelven a quedar en `Block` y las
subidas se rompen otra vez.

Para volver a dejarlas en `Count`, en la consola de AWS WAF: **Web ACLs → scope CloudFront → el
WebACL → cada grupo administrado → Edit → poner todas las reglas en `Count`**.

Por CLI se puede hacer con `aws wafv2 update-web-acl`, agregando un `RuleActionOverrides` por regla
dentro de cada `ManagedRuleGroupStatement`. Respaldar primero, porque `update-web-acl` reemplaza la
definición completa:

```bash
aws wafv2 get-web-acl --scope CLOUDFRONT --region us-east-1 \
  --name CreatedByCloudFront-8f1a9620 \
  --id 61db0a66-3b9d-4224-a1d0-5b13007a1a83 > /tmp/webacl-backup.json
```

El `LockToken` hay que releerlo justo antes de cada `update-web-acl`: cambia con cada modificación.

### Dos límites que cuestan horas si no se saben de antemano

El WebACL creado por el asistente de CloudFront está atado a un **plan de precios** que restringe
qué se le puede hacer:

1. **No admite reglas propias.** Escribir una regla `Allow` que exceptúe las rutas de subida —que
   sería la solución quirúrgica— falla con `WAFFeatureNotIncludedInPricingPlanException`:
   `String match statement` pide plan PRO y `Regex match statement` pide plan BUSINESS.
2. **La distribución no puede quedarse sin WebACL, ni cambiarlo.** `UpdateDistribution` responde
   `You can't remove or replace the web ACL for your distribution. Distributions with a pricing
   plan subscription must have a web ACL resource.`

La suscripción **no tiene API**: no hay operación para cancelarla ni en CloudFront ni en WAFv2. Solo
se cancela desde la consola, en **CloudFront → Distributions → `E2E1XIDYBFNZI9` → Security**. Recién
después se puede quitar el WebACL o reemplazarlo por uno propio.

## Agrupamiento de voces (ARGOS-110 / ADR-026)

Apagado por defecto. Enciende dos cosas a la vez: el agrupamiento de voces en sesiones
presenciales, y la **compuerta** que frena la nota clínica hasta que el profesional dice qué grupo
es el paciente.

La bandera **sale de SSM, no de una variable de entorno**: el workflow de deploy invoca
`deploy-mvp.sh` con una lista fija de variables —solo los tags y la región—, así que una variable
de entorno nunca llegaría. Mismo patrón que `demo-gpu`.

```bash
aws ssm put-parameter --name /argos/mvp/diarizacion-enabled \
  --value true --type String --overwrite
# y volver a desplegar para que el .env de la instancia se regenere
```

**El `.env` de la instancia se regenera entero en cada deploy**, así que editarlo a mano no
sobrevive al siguiente.

**Orden de despliegue:** `Argos-Local` a `main` **primero** —el workflow toma el Compose y el script
de `main`, así que si va después el backend arranca sin las variables—, después transcripción
—trae el encoder WeSpeaker y, como nadie pide agrupar todavía, no cambia nada—, y por último el
backend.

**Reversión:** poner el parámetro en `false` y redesplegar. Las sesiones que quedaron esperando
confirmación se destraban solas al vencer el plazo de `ARGOS_ESPERA_ASIGNACION_HORAS` (24 h por
defecto), o antes con el botón "Continuar sin asignar".

**Qué se puede medir con esto encendido, y qué no.** El DER no: necesita el audio más una anotación
de referencia, y el audio efímero se borra apenas termina el procesamiento. Sí se pueden medir la
tasa de abstención, la cobertura, la distribución del margen contra el 0,30 adoptado, y —la más
útil— cuántos fragmentos corrige el profesional a mano después de asignar, que queda registrado en
`origen_hablante = 'PROFESIONAL'`.

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

Con la EC2 detenida se mantienen únicamente EBS, EIP, ECR, S3 de bajo uso y el dominio. No hay
costo fijo de ALB. CloudFront no tiene cargo fijo pero sí por request y transferencia, ambos
despreciables al volumen actual. Antes y después de cada demo, confirmar que la instancia
`argos-app` esté en estado `stopped`.

## Recuperación

- Los datos de PostgreSQL persisten en el volumen Docker de la EC2.
- Las imágenes conservan tags inmutables `sha-*` para volver a una versión.
- Para rollback, ejecutar `Deploy MVP` indicando los tags `sha-*` previos.
