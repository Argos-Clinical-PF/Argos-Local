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
| Apply en la cuenta nueva | **Pendiente de autorización** |
| Cambio de NS en el registrador | Pendiente |
| Despliegue y restauración de la base | Pendiente |
| Borrado de la cuenta vieja | Pendiente, al final |

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

## Qué no se migra

- **Bucket de grabaciones**: estaba vacío. Las grabaciones se borran solas al vencer la retención
  que consintió el paciente, no son datos a conservar.
- **Bucket de operación**: solo artefactos de despliegue y benchmarks; los regenera el próximo
  deploy.
- **Imágenes ECR**: las reconstruye CI.
