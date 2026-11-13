# Piloto de tokenización de alias

Este módulo usa una raíz y un estado Terraform propios para las Lambdas de escritura y lectura, la bóveda, el registro de auditoría y las claves del piloto. El rol de invocación tiene acceso a los dos alias de Lambda. Los roles de Lambda tienen sus propios permisos de DynamoDB y KMS. El código verifica la credencial RSA del profesional antes de usar la bóveda.

## Prueba local

Requiere Python 3.12, JDK 21 y Docker. Usar una base PostgreSQL efímera y el perfil Spring `piloto-tokenizacion`. La prueba HTTP usa el backend real y el SDK de Lambda. Moto emula DynamoDB y KMS, y un servidor HTTP local captura el envío del Copiloto a un proveedor simulado.

Desde `Argos-Local`, con los repositorios del piloto como carpetas hermanas:

```sh
python3.12 -m venv ../.venv
../.venv/bin/pip install -r terraform/piloto-tokenizacion/lambda/requirements.txt 'moto[kms,dynamodb]==5.2.5'
../.venv/bin/python -m unittest discover -s terraform/piloto-tokenizacion/lambda -p 'test_boveda_alias.py' -v
../.venv/bin/python scripts/piloto-tokenizacion.py --acceso ../acceso-boveda.local.json
```

En otra terminal, desde `Argos-Backend`:

```sh
./mvnw -B -Dtest=TokenizacionAliasIT -Dargos.pruebas.tokenizacion=true \
  "-Dargos.pruebas.boveda.acceso=$(pwd)/../acceso-boveda.local.json" test
```

El emisor genera dos credenciales con una vigencia de 15 minutos. Para repetir después del vencimiento, reiniciar el emisor en un archivo de acceso nuevo. Los archivos de acceso contienen credenciales efímeras y se guardan fuera de los repositorios con permisos 0600.

El test usa las rutas habituales de pacientes. El encabezado `X-Argos-Identidad` acompaña al JWT habitual y se limita a la prueba. El JWT de ARGOS identifica al profesional en Spring. La Lambda comprueba además que la prueba RSA corresponde al mismo profesional y al ámbito dueño del alias. La prueba del volcado compara la fila heredada en claro con el resultado de migrarla mediante edición.

## Preparar el plan AWS

Construir la Lambda en un directorio `.build/lambda` nuevo. AWS aporta el SDK de Python del runtime. Las dependencias de la firma se empaquetan como ruedas Linux para Python 3.13 x86-64.

```sh
mkdir -p .build/lambda
cp lambda/boveda_alias.py lambda/identidad_cognito.py .build/lambda/
python3.12 -m pip install --target .build/lambda --platform manylinux2014_x86_64 \
  --implementation cp --python-version 3.13 --only-binary=:all: -r lambda/requirements.txt
terraform init
terraform fmt -check
terraform validate
terraform plan -var-file=piloto.tfvars.json
```

El archivo `piloto.tfvars.json` lleva la clave **pública** del emisor sintético en `clave_publica`, los dos UUID ficticios en `profesionales` y el ARN IAM del operador del piloto en `principal_de_pruebas`. Guardar las credenciales de firma fuera de Terraform. El proveedor fija la cuenta de ARGOS y la región `us-east-1`.

## Repetir la prueba con AWS

Para preparar el despliegue de pruebas, generar una credencial nueva desde `Argos-Local` con `../.venv/bin/python scripts/piloto-tokenizacion.py --solo-emisor --acceso ../acceso-boveda-aws.local.json`. Copiar `clavePublica` y `profesionales` a las variables correspondientes del plan. Las credenciales duran 15 minutos. Usar el mismo archivo para la prueba y eliminarlo al terminar.

Una vez desplegado el piloto, ejecutar `TokenizacionAliasIT` con la ruta al archivo de acceso de AWS y credenciales STS temporales del rol que devuelve `terraform output -json invocacion`. Antes de iniciar Maven, comprobar con `aws sts get-caller-identity` que la sesión asumió `argos-piloto-boveda-cliente` en la cuenta de ARGOS. El test usa PostgreSQL efímero y mantiene el proveedor de IA simulado.

Con las mismas credenciales STS, verificar que `GetItem` y `Scan` contra la tabla del piloto y `Decrypt` y `GenerateMac` contra sus claves devuelven `AccessDenied`. La verificación de aislamiento requiere esas denegaciones y el éxito de la prueba HTTP con el rol de invocación.

## Alcance del piloto

El piloto cubre el alias del expediente y la redacción de ese alias conocido en el Copiloto. Para operar con datos reales quedan la emisión independiente de credenciales para usuarios reales, la recuperación y reconciliación de versiones entre almacenes, las bajas de identidad, la migración del portal y el control de salida a proveedores con un rol de inferencia propio. La búsqueda parcial todavía usa el parámetro de consulta existente. Antes de habilitar el flujo con identidades reales se debe verificar el tratamiento de ese parámetro en el navegador, el proxy y las trazas.
