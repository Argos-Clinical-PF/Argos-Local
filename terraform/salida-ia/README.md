# Salida de ARGOS a Bedrock

La Lambda valida el formato y busca identificadores directos antes de llamar al proveedor. Consulta el autorizador de ARGOS por HTTPS con una firma Ed25519 y solo metadatos de alcance. El autorizador usa las reglas vigentes de consentimiento en PostgreSQL. Una denegación, un error del autorizador o una respuesta inesperada bloquean la inferencia. El mensaje enviado a Bedrock excluye los metadatos de autorización.

La clave privada de firma se aprovisiona en el parámetro SecureString `/argos/salida-ia/firma-autorizador`. El rol de la Lambda lee ese parámetro. El rol de la EC2 tiene una denegación explícita de lectura del parámetro, de su historial y de los paths que podrían devolverlo. El backend recibe únicamente la clave pública en `/argos/mvp/ia-autorizador-clave-publica`. Este control separa el permiso para invocar Bedrock y la preparación del contexto. El registro de consentimiento en el backend sigue siendo una autoridad de confianza.

## Construcción y plan

```sh
mkdir -p .build/lambda
cp lambda/salida_ia.py .build/lambda/
python3.12 -m pip install --target .build/lambda --platform manylinux2014_x86_64 \
  --implementation cp --python-version 3.13 --only-binary=:all: -r lambda/requirements.txt
terraform init -reconfigure
terraform fmt -check
terraform validate
terraform plan -out=salida-ia-base.tfplan
```

Además de la Lambda, el plan inicial crea su alias, los permisos acotados y el grupo de logs de 14 días. El rol de la aplicación recibe permiso para ese alias. Los cargos dependen de invocaciones, duración y logs. Los perfiles y destinos IAM corresponden a los dos modelos configurados en ARGOS.

## Activación y comprobación

Desplegar el backend y configurar los parámetros de firma. Activar `/argos/mvp/ia-salida-aislada` con `/argos/mvp/ia-salida-profesionales` limitado al UUID del profesional ficticio. Probar Nota Clínica, Temas, Evolución y Copiloto con consentimiento, después de revocar el alcance, con un identificador señuelo y con el autorizador indisponible. Comprobar que Bedrock recibe texto redactado, que las variantes rechazadas carecen de invocación y que la Lambda no publica el cuerpo ni las credenciales.

Después de la aceptación del canario, usar el alcance explícito `todos` y comprobar los flujos. Aplicar el segundo plan con `exigir_salida_aislada=true` y probar que el rol de la app recibe denegación al invocar Bedrock en forma directa.

Durante el canario se puede revertir la activación con `ia-salida-aislada=false` y un nuevo despliegue. Después del corte IAM, mantener el bloqueo directo mientras se corrige o revierte el alias de la Lambda a una versión compatible.
