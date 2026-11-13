# Emisor OIDC de validación para tokenización

Cognito se aloja en la cuenta ARGOS `616322963974`, región `us-east-1`, con estado separado en el bucket de Terraform existente. Este pool tiene altas administradas, MFA TOTP obligatorio y recuperación administrada. El cliente público usa código de autorización con PKCE S256 y un retorno de desarrollo en `localhost`.

## Preparar un cambio

```sh
terraform init -reconfigure
terraform fmt -check -diff
terraform validate
terraform plan -out=emisor-validacion.tfplan
```

Revisar la cuenta, el plan y la clave del estado antes de operar. El resultado `oidc` contiene configuración pública, incluidos el emisor, cliente, audiencia y alcance de validación. Los usuarios ficticios se crean con `MessageAction=SUPPRESS` y se eliminan cuando termina el ensayo. Las contraseñas, claves TOTP y tokens quedan fuera de Terraform, Git y los logs.

## Contrato de acceso

El navegador solicita el alcance del servidor de recursos, genera un `state` por intento y conserva el verificador PKCE hasta el retorno. La bóveda exige la firma RS256 de Cognito, el emisor, el cliente dedicado, el tipo de token de acceso, el alcance de la bóveda y el vencimiento. Cuando el token incluye `aud`, exige que sea la audiencia de la bóveda. Un vínculo aprovisionado fuera del backend une el `sub` inmutable con el UUID interno del profesional. Un sujeto que deja de estar vinculado pierde autorización en la bóveda. Los tokens de acceso duran cinco minutos.

El pool de validación es independiente del login de la app pública y del portal. Para producción quedan el enrolamiento, la recuperación y la revocación del vínculo, las URL HTTPS de retorno y la autorización acotada de los trabajos pos-sesión. La protección contra eliminación del pool queda activa. Para retirarlo se revisa primero su uso, se desactiva esa protección con un cambio explícito y luego se elimina el stack.
