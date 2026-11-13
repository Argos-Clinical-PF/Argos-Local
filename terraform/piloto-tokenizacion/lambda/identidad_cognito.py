import json
import os
import re
from functools import lru_cache

import jwt


@lru_cache(maxsize=1)
def claves(emisor):
    if not re.fullmatch(r"https://cognito-idp\.us-east-1\.amazonaws\.com/us-east-1_[A-Za-z0-9]+", emisor):
        raise ValueError("Emisor de Cognito no válido para ARGOS")
    return jwt.PyJWKClient(emisor + "/.well-known/jwks.json", lifespan=300, timeout=2)


def identificar(prueba):
    emisor = os.environ["COGNITO_EMISOR"]
    llave = claves(emisor).get_signing_key_from_jwt(prueba)
    datos = jwt.decode(
        prueba,
        llave.key,
        algorithms=["RS256"],
        issuer=emisor,
        options={"verify_aud": False, "require": ["sub", "iat", "exp", "iss", "client_id", "token_use", "scope"]},
    )
    if (
        datos["token_use"] != "access"
        or datos["client_id"] != os.environ["COGNITO_CLIENTE"]
        or os.environ["COGNITO_ALCANCE"] not in datos["scope"].split()
        or ("aud" in datos and datos["aud"] != os.environ["COGNITO_AUDIENCIA"])
        or not 0 < datos["exp"] - datos["iat"] <= 300
    ):
        raise jwt.InvalidTokenError("Credencial fuera del alcance de la bóveda")
    return json.loads(os.environ["COGNITO_VINCULOS"]).get(datos["sub"])
