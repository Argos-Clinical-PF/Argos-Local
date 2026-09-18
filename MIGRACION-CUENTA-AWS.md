# Migración a la cuenta AWS 616322963974

La cuenta vieja (`915093573341`, perfil `argos-facu`) se quedó sin crédito. Todo se rehace en la
cuenta nueva (`616322963974`, perfil `argos-nuevos`, región `us-east-1`), que arrancó vacía.

El dominio `argosclinical.online` está registrado en un registrador externo, no en Route53 Domains:
no hay transferencia de dominio, solo un cambio de NS.

## Estado al 17/09/2026

| Paso | Estado |
|---|---|
| Respaldo de la base de la cuenta vieja | Hecho. `~/argos-respaldo-migracion/argos-2026-09-17.dump` (647 KB, 53 tablas: 11 profesionales, 44 pacientes, 331 sesiones, 123 notas) |
| Respaldo de fotos de perfil | Hecho, vacío (no había ninguna) |
| Copia de los 12 parámetros `/argos/mvp/*` | Hecha. `encryption-key` verificada por huella SHA-256: idéntica en ambas cuentas |
| Terraform listo para la cuenta nueva | Hecho. `terraform plan` en el workspace `cuenta-nueva`: 48 recursos a crear, 0 a cambiar |
| Apply en la cuenta nueva | Hecho (18/09/2026): certificado validado desde la zona vieja, CloudFront y apex/www creados |
| Cambio de NS en el registrador | Pendiente (recomendado, ya no bloquea: la zona vieja apunta al stack nuevo) |
| Despliegue y restauración de la base | Hecho |
| Borrado de la cuenta vieja | Hecho salvo la distribución de CloudFront (plan de precios) y el usuario `ia` |

La instancia vieja quedó **detenida** otra vez después del respaldo.

## Qué cambió en el código

- `terraform/main.tf`: la zona Route53, el certificado ACM y su validación DNS pasaron de `data` a
  recursos. En una cuenta vacía no hay nada que leer, y como `data` obligaban a prepararlos a mano
  antes del primer apply.
- WebACL propio opcional (`waf_habilitado`, apagado por defecto). El de la cuenta vieja lo creó el
  asistente de CloudFront y quedó atado a una suscripción de plan de precios que no admite reglas
  propias, no se puede desasociar y solo se cancela desde la consola (ADR-023). Creando la
  distribución por Terraform esa suscripción no existe, así que el WebACL nuevo sí acepta una regla
  `Allow` para las tres rutas multipart, que es lo que rompió las subidas en agosto. Además deja en
  `Count` las reglas que inspeccionan el cuerpo, como segunda red.
- `.github/workflows/deploy.yml` y `operate.yml`: el ARN del rol OIDC apunta a la cuenta nueva.
- `scripts/copiar-parametros-ssm.sh` y `scripts/restaurar-respaldo.sh`.

## Estado de Terraform

El workspace `default` sigue teniendo el estado de la cuenta vieja; la cuenta nueva vive en el
workspace `cuenta-nueva`. **No aplicar en `default`**: la configuración actual crearía zona y
certificado también ahí. Para destruir la cuenta vieja al final, `terraform destroy` en `default`
funciona igual porque el destroy se arma desde el estado.

```bash
cd terraform
terraform workspace select cuenta-nueva
terraform plan
```

## Orden de corte

1. **Apply en la cuenta nueva.**
   ```bash
   cd terraform && terraform workspace select cuenta-nueva && terraform apply
   ```
   El apply se queda esperando la validación del certificado hasta que los NS del dominio apunten a
   la zona nueva, así que el paso 2 va en paralelo.

2. **Cambiar los NS en el registrador** por los cuatro de la zona nueva:
   ```bash
   terraform output -raw name_servers 2>/dev/null || \
     aws route53 get-hosted-zone --profile argos-nuevos \
       --id "$(aws route53 list-hosted-zones --profile argos-nuevos \
         --query "HostedZones[?Name=='argosclinical.online.'].Id" --output text)" \
       --query 'DelegationSet.NameServers' --output text
   ```
   Propagación típica: minutos a un par de horas. El sitio ya está caído (instancia detenida), así
   que no hay ventana que cuidar.

3. **Publicar imágenes y desplegar.** Los workflows ya apuntan al rol de la cuenta nueva; el rol lo
   crea este mismo Terraform. Requiere que el código del rediseño esté en `main`.

4. **Restaurar la base** una vez que el stack responde:
   ```bash
   ./scripts/restaurar-respaldo.sh ~/argos-respaldo-migracion/argos-2026-09-17.dump
   ```
   El script detiene el backend, restaura con `--clean --if-exists` y lo vuelve a levantar. Como la
   `encryption-key` es la misma, las notas clínicas siguen siendo legibles.

5. **Verificar**: HTTPS en el dominio, login, una sesión con su nota, y que el CSV de pacientes baje.

6. **Recién entonces, vaciar la cuenta vieja.** Antes de esto, confirmar que el punto 5 pasó.
   ```bash
   cd terraform && terraform workspace select default && terraform destroy
   ```
   Lo que el destroy no cubre (creado a mano en su momento): la zona vieja, el certificado viejo y
   la suscripción del plan de precios de CloudFront, que se cancela desde la consola.

## Ventana de corte: parámetros que cambian dos veces

Mientras los NS sigan apuntando a la cuenta vieja, el dominio lo sirve el stack viejo. Si el deploy
se valida contra el dominio, el smoke test pasa contra la cuenta muerta y no prueba nada, y Caddy
pide un certificado para `origin.argosclinical.online`, que resuelve a la IP vieja y nunca se emite.

Por eso, durante el corte, los dos parámetros apuntan a la instancia nueva por IP:

| Parámetro | Durante el corte | Después de mover los NS |
|---|---|---|
| `/argos/mvp/public-base-url` | `https://nuevo.argosclinical.online` | `https://argosclinical.online` |
| `/argos/mvp/origin-base-url` | `https://nuevo.argosclinical.online` | `https://origin.argosclinical.online` |
| `origenes_cors_adicionales` (terraform.tfvars, local) | `["https://nuevo.argosclinical.online"]` | `[]` |

`nuevo.argosclinical.online` es un registro A hacia la instancia nueva, creado en **las dos zonas**:
en la vieja (que es la autoritativa hasta que se muevan los NS) y en la nueva, así sobrevive al
corte. Existe porque `sslip.io`, que es lo que arma `deploy-mvp.sh` cuando el origen es una IP
desnuda, no resuelve detrás de muchos routers domésticos: la protección contra DNS rebinding lo
bloquea y el navegador falla antes de llegar al servidor. Con un nombre del dominio propio, Caddy
además emite un certificado real para él.

```bash
aws ssm put-parameter --profile argos-nuevos --overwrite --type String \
  --name /argos/mvp/public-base-url --value https://argosclinical.online
aws ssm put-parameter --profile argos-nuevos --overwrite --type String \
  --name /argos/mvp/origin-base-url --value https://origin.argosclinical.online
```

Volver a desplegar después de cambiarlos: el `.env` de la instancia se arma con esos valores.

## Lo que encontró la auditoría previa al corte

Ya corregido en este commit:

- `Argos-Entrenamiento` seguía publicando las imágenes de transcripción y emociones contra el rol
  de la cuenta muerta. Es el repo que construye esas dos imágenes; ningún otro las construye.
- El presupuesto medía gasto **neto de crédito**: marcaba USD 0,00 y solo iba a avisar cuando el
  crédito ya estuviera consumido, que es como murió la cuenta anterior.
- El rol de GitHub Actions confiaba en cualquier rama de los cinco repos.
- El ciclo de vida del bucket de operación no cubría `respaldo-migracion/`, así que el volcado con
  las historias clínicas se quedaba ahí para siempre.
- ECR conservaba 15 imágenes por repo (unos 19 GB); ahora 5.
- El default de `var.profile` era `argos-facu`: un clon nuevo aplicaba contra la cuenta muerta.

Pendiente, para después del corte:

- El bucket de grabaciones sólo admite CORS desde `https://<domain_name>`. Mientras la app se sirve
  desde `nuevo.argosclinical.online`, ese host va en `origenes_cors_adicionales` (terraform.tfvars,
  que no se versiona) o el navegador no puede subir ninguna parte y las grabaciones quedan en
  `INICIADA` sin que nadie lo note: así pasó el 18/09. Al mover los NS, vaciar la lista y aplicar.
- La cuenta vieja sigue gastando del orden de USD 11/mes con todo apagado, incluida una IP elástica
  huérfana en **us-east-2** que ningún terraform maneja (`eipalloc-0e5f635693a39ec2a`).
- Los 8 SecureString siguen existiendo en la cuenta vieja, idénticos a los nuevos. Borrarlos al
  vaciarla, o rotarlos.
- En la cuenta vieja hay usuarios con AdministratorAccess y claves estáticas activas que nadie usa.
- `operate.yml` con `action=start` corre `refresh-ip-certificate.sh`, que no existe hasta el primer
  deploy: encender la instancia desde el workflow falla en una máquina recién creada.
- El data source de la AMI matchea también las variantes ECS y minimal, así que la instancia nueva
  no arrancó sobre la misma imagen que la vieja.

## Qué no se migra

- **Bucket de grabaciones**: estaba vacío. Las grabaciones se borran solas al vencer la retención
  que consintió el paciente, no son datos a conservar.
- **Bucket de operación**: solo artefactos de despliegue y benchmarks; los regenera el próximo
  deploy.
- **Imágenes ECR**: las reconstruye CI.

## Estado al 18/09/2026: el dominio ya sirve el stack nuevo sin cambiar los NS

El certificado de la cuenta nueva se validó agregando su CNAME de validación a la zona vieja,
que sigue siendo la autoritativa. Con eso el `apply` de la cuenta nueva creó CloudFront
(`E1NVBUHYJC6UL0`, `d1x0lx8lzaiakb.cloudfront.net`) y los registros apex/www en la zona nueva; en
la zona vieja se apuntaron a mano apex y www (alias a esa distribución) y `origin` (A a la
instancia nueva). Los parámetros `public-base-url` y `origin-base-url` ya valen el dominio.

El cambio de NS en Hostinger sigue siendo lo correcto (la zona nueva tiene los mismos registros),
pero ya no condiciona nada. Después del cambio, vaciar `origenes_cors_adicionales` en el
terraform.tfvars local y aplicar.

De la cuenta vieja se destruyó todo el stack (Terraform, workspace `default`, `-var
profile=argos-facu`), se vaciaron los buckets y el ECR, se liberó la IP elástica de us-east-2, se
borraron los 12 parámetros SSM, el presupuesto manual, `rds-monitoring-role` y los usuarios IAM
con claves estáticas. Los dos respaldos de la base están en
`s3://argos-mvp-operacion-616322963974/respaldo-migracion/`. Queda, a mano y con root:

- Cancelar el "plan de precios" de CloudFront en la consola de la cuenta vieja y borrar la
  distribución `E2E1XIDYBFNZI9` (ya deshabilitada y sin aliases; la API no deja borrarla mientras
  esté suscripta al plan y la CLI no tiene comando para cancelarlo).
- Borrar el certificado ACM viejo cuando no quede ninguna distribución.
- Borrar el usuario `ia` (son las credenciales con las que se hizo la limpieza) y cerrar la cuenta.
