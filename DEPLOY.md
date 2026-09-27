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

Desde `Argos-Local/terraform`, con un perfil de la cuenta 616322963974:

```bash
export AWS_PROFILE=argos-nuevos   # o el perfil propio de esa cuenta
terraform init
terraform workspace select cuenta-nueva
terraform plan
terraform apply
terraform output
```

Si falla con `Unable to locate credentials`, listar los perfiles disponibles con
`aws configure list-profiles`.

Terraform administra EC2/EIP, ECR, S3 operativo, SSM, IAM, CloudFront, la página de pausa, el
grupo de logs y el rol OIDC `argos-github-actions`.

### Estado de Terraform

El estado vive en S3, en `argos-terraform-estado-616322963974` (versionado y cifrado), con bloqueo
nativo de S3 (`use_lockfile`, Terraform 1.11 o posterior): todos ven el mismo estado y dos `apply`
simultáneos no se pisan. El workspace de la cuenta es `cuenta-nueva` (clave
`env:/cuenta-nueva/argos/terraform.tfstate`). El bucket se crea a mano, fuera de este estado, para
que Terraform no administre el lugar donde se guarda a sí mismo.

Migración desde el estado local (una sola vez, desde la máquina que tiene
`terraform/terraform.tfstate.d/cuenta-nueva/`):

1. Crear el bucket:

   ```bash
   export AWS_PROFILE=argos-nuevos
   BUCKET=argos-terraform-estado-616322963974
   aws s3api create-bucket --bucket "$BUCKET" --region us-east-1
   aws s3api put-bucket-versioning --bucket "$BUCKET" \
     --versioning-configuration Status=Enabled
   aws s3api put-bucket-encryption --bucket "$BUCKET" --server-side-encryption-configuration \
     '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"},"BucketKeyEnabled":true}]}'
   aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
     BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
   aws s3api put-bucket-policy --bucket "$BUCKET" --policy "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Sid\":\"DenyInsecureTransport\",\"Effect\":\"Deny\",\"Principal\":\"*\",\"Action\":\"s3:*\",\"Resource\":[\"arn:aws:s3:::$BUCKET\",\"arn:aws:s3:::$BUCKET/*\"],\"Condition\":{\"Bool\":{\"aws:SecureTransport\":\"false\"}}}]}"
   ```

2. Respaldar el estado local y sacar del medio el workspace `default`, que es de la cuenta vieja
   (915093573341) y no debe terminar en el bucket de la nueva:

   ```bash
   cd terraform
   RESPALDO=~/argos-tfstate-respaldo-$(date +%Y%m%d)
   mkdir -p "$RESPALDO"
   cp -R terraform.tfstate.d "$RESPALDO"/
   mv terraform.tfstate terraform.tfstate.*backup "$RESPALDO"/
   ```

3. Migrar (responder `yes` a copiar los workspaces a `s3`):

   ```bash
   terraform init -migrate-state
   terraform workspace select cuenta-nueva
   terraform plan    # solo los cambios pendientes del código, nunca "48 to add"
   aws s3 ls "s3://$BUCKET" --recursive
   ```

4. Con el plan correcto, sacar el estado local del repositorio para que nadie lo use por error:
   `mv terraform.tfstate.d "$RESPALDO"/terraform.tfstate.d-migrado`.

## Parámetros SSM

Los secretos se almacenan cifrados en Parameter Store bajo `/argos/mvp/`:

```text
public-base-url
postgres-password
jwt-secret
mail-username
mail-password
whisper-model
secreto-origen-cloudfront
```

Nunca guardar estos valores en GitHub, archivos versionados ni salidas de CI.

### Secreto de origen de CloudFront

El backend limita el login, la recuperación de contraseña y los reportes de error por la IP real del
visitante, que CloudFront informa en `CloudFront-Viewer-Address`. Como el origen también es alcanzable
directo por 443, ese header solo se acepta si la request trae `X-Argos-Origen` con el secreto que
agrega CloudFront; si no, se limita por la IP de la conexión.

Orden para activarlo (o rotarlo), porque un backend con el secreto y un CloudFront sin él haría que
todos los usuarios de un mismo borde compartan un único límite:

1. Crear el parámetro, solo hexadecimal para que no haya que escapar nada en el `.env`:
   `aws ssm put-parameter --profile argos-nuevos --region us-east-1 --name /argos/mvp/secreto-origen-cloudfront --type SecureString --value "$(openssl rand -hex 32)"` (para rotar, `--overwrite`).
2. `terraform plan` y `terraform apply`: la distribución se actualiza en el lugar y agrega el header al
   origen `argos-ec2-origin`. Esperar a que quede `Deployed`.
3. Recién entonces desplegar (Release MVP): `deploy-mvp.sh` escribe `ARGOS_SECRETO_CLOUDFRONT` en el `.env`.

Sin el parámetro, el deploy deja el secreto vacío y el backend confía siempre en `CloudFront-Viewer-Address`
(como antes); el `terraform plan` falla hasta crear el parámetro del paso 1.

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

## La EC2 se detiene sola después de cada release

El workflow reutilizable de deploy apaga la instancia al terminar, incluso cuando el despliegue
falla (salvo cuando el gate de trabajo clínico lo canceló: ahí hay alguien usándola). Es deliberado —fuera de demos la EC2 no debe quedar encendida— pero tiene un efecto que
sorprende: **cada merge a `main` deja el sitio abajo** hasta que alguien lo vuelve a levantar.

Durante un período de demo eso es justamente lo que no se quiere. La variable de repositorio
`DETENER_EC2_TRAS_DEPLOY` lo controla sin tocar el workflow.

> **Va en los repos que LLAMAN al workflow, no en `Argos-Local`.** `deploy.yml` es un workflow
> reutilizable: el contexto `vars` que ve es el del repositorio que lo invoca. Definirla sólo en
> `Argos-Local` no tiene ningún efecto sobre un deploy disparado por un merge en el backend o el
> frontend — el deploy corre igual y apaga la instancia.

```bash
# La instancia queda encendida después de cada deploy (período de demo)
for repo in Argos-Backend Argos-Frontend Argos-Local; do
  gh variable set DETENER_EC2_TRAS_DEPLOY --body false --repo "Argos-Clinical-PF/$repo"
done

# Vuelve al comportamiento de ahorro
for repo in Argos-Backend Argos-Frontend Argos-Local; do
  gh variable set DETENER_EC2_TRAS_DEPLOY --body true --repo "Argos-Clinical-PF/$repo"
done
```

Con permisos de administrador de la organización alcanza con definirla una vez a nivel org
(`gh variable set ... --org Argos-Clinical-PF --visibility all`).

Con la variable en `false` **la instancia queda corriendo y genera costo**: hay que detenerla a
mano al terminar, con `Operate MVP` acción `stop`. Antes y después de cada jornada de demo,
confirmar el estado de la instancia.

## Costos

Con la EC2 detenida se mantienen únicamente EBS, EIP, ECR, S3 de bajo uso y el dominio. No hay
costo fijo de ALB. CloudFront no tiene cargo fijo pero sí por request y transferencia, ambos
despreciables al volumen actual. Antes y después de cada demo, confirmar que la instancia
`argos-app` esté en estado `stopped`.

## Cómo se aplica un release

`deploy-mvp.sh` corre en la instancia por SSM y hace, en orden:

1. **Gate de trabajo clínico.** Si `argos-backend` está corriendo, consulta
   `/api/health/deployment-safety` (sesiones `EN_CURSO` o `FINALIZANDO`, jobs post-sesión, audios
   y cargas pendientes). Si no es seguro, sale con código 75 sin tocar nada: el run falla con
   «Deploy cancelado», no revierte y no apaga la instancia. Reintentar cuando termine, o relanzar
   `Release MVP` a mano con `forzar=true` sabiendo que corta la sesión en vivo. Si el backend no
   responde, no hay sesión que proteger y sigue. Si el workflow tuvo que encender la EC2, el gate se
   omite: recién encendida no puede haber una sesión en vivo. Una sesión que quedó `EN_CURSO`
   porque nadie la finalizó también bloquea: finalizarla desde la app o usar `forzar=true`.
2. Copia el bundle, que el workflow dejó en `/home/ec2-user/argos/entrante/`, a la carpeta de la
   app: un deploy cancelado no deja un `Caddyfile` ni un compose sin desplegar junto al `.env`
   viejo. Regenera el `.env`, baja las imágenes, toma un respaldo (dump y fotos) e instala los
   timers.
3. `docker compose up -d --remove-orphans`, sin `down`: solo se recrean los servicios cuya imagen o
   configuración cambió, así que un release del frontend reinicia solo nginx y no Postgres ni los
   modelos. El hash del `Caddyfile` va como label del gateway para que un cambio de ese archivo
   también lo recree.
4. Renueva el certificado de la IP solo si vence en menos de 3 días (certbot detiene el gateway
   unos segundos).

### Rollback automático

Si el comando de deploy o el smoke test fallan, el workflow vuelve solo al último manifiesto
promovido (`deploy/manifests/current.json`, que no cambió) con el bundle de ese release, repite el
smoke test y el run termina igual en rojo. El resumen del run dice a qué release volvió. No revierte
cuando el gate canceló el deploy (no cambió nada), cuando la acción era un `rollback` manual, ni
cuando el comando SSM seguía corriendo. Los bundles de `deploy/releases/` se borran a los 365
días; los manifiestos no se borran. Si el bundle del último release promovido ya no existe, el run
lo avisa: relanzar `Release MVP` con `action: deploy` y `service: bundle`, que toma los tags de
`current.json` con el bundle de main.

## Logs

Los contenedores escriben en CloudWatch Logs, grupo `/argos/mvp`, un stream por contenedor
(`argos-backend`, `argos-frontend`, ...), con 14 días de retención. Sobreviven a los deploys y al
apagado. `docker logs` sigue funcionando en la instancia, pero solo desde la última vez que se
recreó el contenedor. El driver está en modo `non-blocking`: si CloudWatch no responde se descartan
líneas, la aplicación no se frena.

```bash
aws logs tail /argos/mvp --log-stream-names argos-backend --since 2h --follow
```

p95 de la API en CloudWatch Logs Insights (grupo `/argos/mvp`), sobre el formato `argos` de nginx:

```text
filter @logStream = "argos-frontend" and @message like /"(GET|POST|PUT|PATCH|DELETE) \/api\//
| parse @message "rt=* urt=*" as rt, urt
| stats pct(rt, 95) as p95_total, pct(urt, 95) as p95_backend, count(*) as pedidos by bin(1h)
```

## Vigía de contenedores

Docker reinicia un contenedor solo cuando su proceso termina: uno colgado (JVM sin memoria, Whisper
trabado) queda `unhealthy` indefinidamente. `deploy-mvp.sh` instala `argos-vigia.timer`, que cada
minuto cuenta los chequeos seguidos en que cada contenedor `argos-*` figura `unhealthy` y al tercero
lo reinicia, dejando el último resultado del healthcheck en el journal:

```bash
journalctl -u argos-vigia --since today
```

No manda alertas por mail ni SNS (decisión de costo) y no corre con la instancia detenida.

## Con la instancia detenida: página de pausa

CloudFront intenta la EC2 una sola vez, con 5 s para conectar. Si no conecta, o contesta 500, 502,
503 o 504, las navegaciones (GET, HEAD) reciben «ARGOS está en pausa» desde el bucket
`argos-mvp-pausa-616322963974`. La fuente es `terraform/pausa/index.html` y se publica con
`terraform apply`. La misma página aparece los segundos en que un deploy recrea el frontend.

- `/api/*` y `/public/*` van directo a la EC2, sin caché ni failover: con la instancia detenida
  responden el 504 de CloudFront en unos 5 s, y los 502, 504 y 404 del backend llegan tal cual.
- `/assets/*` se cachea en el borde (Managed-CachingOptimized): los nombres llevan hash y nginx los
  marca `immutable`. El HTML no se cachea, así que un deploy se ve enseguida.
- La página responde 200 en `/` y 404 en cualquier otra ruta (es el documento de error del sitio
  S3). El navegador la muestra igual.
- El bucket es público a propósito, porque el endpoint de sitio web de S3 no admite acceso privado
  desde CloudFront. No guardar ahí nada más que esa página. CloudFront le habla por HTTP (ese
  endpoint no tiene HTTPS), así que las navegaciones no reenvían cookies ni query string a ningún
  origen. El path sí viaja: en un failover, el token de un link de consentimiento
  (`/consentimiento/:token`, `/consentimiento/revocar/:token`) llega por HTTP al bucket. Por eso
  nunca activar el registro de accesos del servidor (server access logging) en
  `argos-mvp-pausa-616322963974`: guardaría esos tokens.

Verificación con la instancia detenida (se espera `200` y `504`, ambos en unos 5 s):

```bash
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' https://argosclinical.online/
curl -s -o /dev/null -w '%{http_code} %{time_total}s\n' https://argosclinical.online/api/health
```

## Timeouts: lo síncrono responde antes de los 60 s de CloudFront

CloudFront corta cada pedido al origen a los 60 s (`origin_read_timeout`; subirlo requiere pedir a
AWS un aumento de cuota). Pasado ese tiempo el navegador recibe el 504 de CloudFront aunque el
backend siga trabajando, y el reintento duplica el trabajo: otra transcripción o otra llamada a
Bedrock que se cobra.

| Camino | Peor caso | Dónde se configura |
|---|---|---|
| Fragmento de transcripción en vivo | 3 intentos de 15 s + 1 s + 2 s de espera = 48 s | `TRANSCRIPCION_REALTIME_TIMEOUT_SECONDS=15` y `TRANSCRIPCION_REALTIME_RETRIES=2` en `deploy-mvp.sh` y `docker-compose.prod.yml` |
| Cuadro de análisis emocional | 5 s | `EMOCIONES_TIMEOUT_MS` en `docker-compose.prod.yml` |
| Envío del fragmento desde el navegador | espera 100 s | `GrabacionSesion.tsx` (frontend); el backend ya responde antes de 60 s |
| Nota clínica y asistente | hasta 2 llamadas de 90 s (nota) o 60 s (asistente) | fijo en `ClienteClaudeIA` (backend); la regeneración pasa a segundo plano en otro cambio |
| Proxy `/api/` de nginx | 180 s | `nginx.conf` del frontend; no limita, CloudFront corta antes |

## Respaldos y recuperación

| Respaldo | Cuándo | Retención | Qué tiene |
|---|---|---|---|
| Snapshot del disco (DLM, etiqueta `Proyecto=argos`) | todos los días 07:00 UTC, aun con la instancia detenida | 7 snapshots | todo el disco: base, fotos, certificados, `.env` |
| `s3://argos-mvp-operacion-616322963974/backups/argos-<fecha>.dump` | cada 6 h con la instancia encendida y antes de cada deploy | 14 días | la base (`pg_dump -Fc`) |
| `.../backups/perfiles-<fecha>.tar` | junto con cada dump | 14 días | las fotos de perfil (volumen `argos-profile-uploads`) |

Lo escrito entre el último dump y el apagado solo queda en el snapshot del día siguiente. Las
grabaciones viven en su propio bucket y no dependen de la instancia. Transcripciones y notas están
cifradas con el parámetro `/argos/mvp/encryption-key`: un dump solo se lee con la misma clave, así
que no rotarla ni borrarla antes de restaurar. Las imágenes conservan tags inmutables `sha-*`.

Elegir el respaldo más nuevo:

```bash
export AWS_PROFILE=argos-nuevos
aws s3 ls s3://argos-mvp-operacion-616322963974/backups/ | sort | tail -4
aws ec2 describe-snapshots --owner-ids self --filters Name=tag:Proyecto,Values=argos \
  --query 'reverse(sort_by(Snapshots,&StartTime))[:3].[SnapshotId,StartTime,State]' --output table
INSTANCIA=$(aws ec2 describe-instances --filters Name=tag:Name,Values=argos-app \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
```

### A. Datos dañados, la instancia existe: volver a un snapshot

Reemplaza el disco raíz sin cambiar la instancia, la IP ni el rol. Requiere la instancia encendida
y se reinicia sola; se pierde lo escrito después del snapshot.

1. `aws ec2 start-instances --instance-ids "$INSTANCIA" && aws ec2 wait instance-running --instance-ids "$INSTANCIA"`
2. `aws ec2 create-replace-root-volume-task --instance-id "$INSTANCIA" --snapshot-id snap-...`
3. Esperar `succeeded` en
   `aws ec2 describe-replace-root-volume-tasks --filters Name=instance-id,Values="$INSTANCIA"`.
4. Verificar que el disco nuevo tenga las etiquetas de las que depende el snapshot diario, y
   ponerlas si faltan:

   ```bash
   VOLUMEN=$(aws ec2 describe-instances --instance-ids "$INSTANCIA" \
     --query 'Reservations[0].Instances[0].BlockDeviceMappings[0].Ebs.VolumeId' --output text)
   aws ec2 describe-tags --filters Name=resource-id,Values="$VOLUMEN"
   aws ec2 create-tags --resources "$VOLUMEN" \
     --tags Key=Respaldo,Value=argos-diario Key=Name,Value=argos-app-raiz
   ```

5. Correr `Operate MVP` con `start`: renueva el certificado de la IP y espera la salud.
6. Con todo verificado, borrar el volumen anterior (queda desasociado y se sigue cobrando).

### B. La instancia se perdió: instancia nueva y dump

Anotar ahora la marca `<fecha>` del dump y del tar de fotos a restaurar: unos 20 minutos después de
encender la instancia nueva, `argos-respaldo-base` sube un dump de la base vacía y un tar vacío que
pasan a ser los más nuevos de `backups/`.

1. Recrear la instancia. Conserva la IP elástica, el rol y las etiquetas del disco:
   `cd terraform && terraform workspace select cuenta-nueva && terraform apply -replace aws_instance.app`
2. Correr `Release MVP` a mano (`action: deploy`, `service: bundle`, `stop_after: false`). Instala el
   stack con una base vacía.
3. Restaurar la base desde el dump anotado, con el backend en la misma versión que tenía al
   tomarlo (si el backend actual trae migraciones posteriores, `pg_restore --clean` deja tablas de
   más y Flyway falla al recrearlas: en ese caso vaciar antes el esquema con el backend detenido,
   `DROP SCHEMA public CASCADE; CREATE SCHEMA public;`):

   ```bash
   aws s3 cp s3://argos-mvp-operacion-616322963974/backups/argos-<fecha>.dump ./restaurar.dump
   ./scripts/restaurar-respaldo.sh ./restaurar.dump argos-nuevos
   rm ./restaurar.dump   # es una copia de historias clínicas
   ```

4. Restaurar las fotos de perfil del mismo momento que el dump:

   ```bash
   aws ssm send-command --instance-ids "$INSTANCIA" --document-name AWS-RunShellScript \
     --parameters 'commands=["aws s3 cp s3://argos-mvp-operacion-616322963974/backups/perfiles-<fecha>.tar - | docker cp -a - argos-backend:/app/uploads/"]'
   ```

5. Verificar ingresando a la app (un paciente, una nota, una foto) y detener la instancia.

Todavía no se hizo un simulacro cronometrado: la primera vez, anotar acá cuánto tardó cada camino.

## Pasar a GPU (g6.2xlarge) y volver a CPU

Requiere la cuota "Running On-Demand G and VT instances" en 8 o más (pedida el 25/09/2026). Con GPU,
la transcripción en vivo usa large-v3-turbo y el pase post-sesión deja de tardar decenas de minutos.
Precio mientras corre: 0,98 USD/h (CPU: 0,36 USD/h); se sigue deteniendo la instancia al terminar.

1. Detener la instancia y cambiar el tipo con Terraform (plan verificado: cambio en el lugar, la base
   se conserva):
   `cd terraform && TF_WORKSPACE=cuenta-nueva terraform apply -var demo_gpu=true`
2. Encenderla y correr una sola vez, por SSM, `scripts/habilitar-gpu.sh` (driver NVIDIA y runtime de
   contenedores). Termina mostrando `nvidia-smi`.
3. `aws ssm put-parameter --name /argos/mvp/demo-gpu --value true --overwrite` (y, si se quiere otro
   modelo en vivo, `/argos/mvp/whisper-model-gpu`).
4. Redesplegar el bundle (`deploy.yml`, service=bundle). El overlay `docker-compose.gpu.yml` usa la
   imagen de transcripción con sufijo `-gpu`.

Para volver a CPU: parámetro `demo-gpu=false`, `terraform apply -var demo_gpu=false` y redesplegar.
El driver instalado no molesta en una instancia sin GPU.

