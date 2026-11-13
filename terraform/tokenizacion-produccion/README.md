# Bóveda de alias de ARGOS en producción

El estado de este módulo vive en el bucket de Terraform de ARGOS bajo `argos/tokenizacion/produccion.tfstate`. La cuenta es `616322963974` y la región es `us-east-1`. La aplicación tiene permiso para invocar los dos alias `produccion`. La administración de Cognito, los vínculos y las claves usa un principal independiente del despliegue de la aplicación.

```sh
mkdir -p .build/lambda
cp ../piloto-tokenizacion/lambda/{boveda_alias,identidad_cognito}.py .build/lambda/
python3.12 -m pip install --target .build/lambda --platform manylinux2014_x86_64 \
  --implementation cp --python-version 3.13 --only-binary=:all: \
  -r ../piloto-tokenizacion/lambda/requirements.txt
terraform init -reconfigure
terraform fmt -check -diff
terraform validate
terraform plan -var administrador_boveda=ARN_DEL_ADMINISTRADOR -out=boveda-produccion.tfplan
```

## Alta y baja de acceso

Crear la identidad en Cognito mediante alta administrada y completar la verificación de titularidad. Vincular el `sub` verificado con el UUID del profesional en `argos-boveda-produccion-vinculos` mediante una escritura condicional que rechace un vínculo previo. Para revocar, establecer `activo=false` con condición sobre el UUID esperado y deshabilitar la cuenta en Cognito. La bóveda lee el vínculo con consistencia fuerte en cada invocación, también cuando un trabajador usa un permiso de nota vigente.

La aplicación activa el perfil `tokenizacion-produccion` cuando existen los parámetros `/argos/mvp/tokenizacion-cliente-cognito` y `/argos/mvp/tokenizacion-profesionales`. Se debe desplegar primero en la cohorte ficticia y verificar la autenticación, alta, consulta, exportación, revocación y las solicitudes al proveedor con datos sintéticos. La credencial de Cognito dura cinco minutos y se guarda en una cookie segura. Con consentimiento vigente, ARGOS obtiene al iniciar la sesión un permiso de hasta 24 horas para el expediente, la sesión y la referencia del alias. Se conserva cifrado en PostgreSQL mientras lo necesita el procesamiento. La bóveda vuelve a verificar el vínculo del profesional cuando se usa.

## Migración y recuperación

La ruta `POST /api/patients/{id}/identidad/proteger` migra una ficha del profesional autenticado y permite reintentar con la misma referencia cuando falla la publicación en PostgreSQL. Ensayar el alta y el acceso con datos sintéticos. Registrar un punto de recuperación común para PostgreSQL y DynamoDB y conservar las claves KMS vigentes. Validar referencias y revocaciones en las copias aisladas antes de mover tráfico.

Ante un fallo de activación, detener las altas de la cohorte. Mantener un backend compatible con referencias tokenizadas y recuperar los almacenes como unidad. Las imágenes anteriores que leen solo `pacientes.alias` requieren un respaldo previo a la migración y perderían las escrituras posteriores si se restaurara ese respaldo.
