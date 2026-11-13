import json
import os
import re
from functools import lru_cache
from uuid import UUID

import jwt


@lru_cache(maxsize=1)
def claves(emisor):
    if not re.fullmatch(r"https://cognito-idp\.us-east-1\.amazonaws\.com/us-east-1_[A-Za-z0-9]+", emisor):
        raise ValueError("Emisor de Cognito no válido para ARGOS")
    return jwt.PyJWKClient(emisor + "/.well-known/jwks.json", lifespan=300, timeout=2)


def identificar(prueba, ddb):
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
    sujeto = str(UUID(datos["sub"]))
    return sujeto, profesional_activo(ddb, sujeto)


def profesional_activo(ddb, sujeto):
    tabla = os.getenv("TABLA_VINCULOS")
    if not tabla:
        return json.loads(os.environ["COGNITO_VINCULOS"]).get(sujeto)
    vinculo = ddb.get_item(
        TableName=tabla,
        Key={"sujeto": {"S": sujeto}},
        ConsistentRead=True,
    ).get("Item", {})
    if vinculo.get("activo", {}).get("BOOL") is not True:
        return None
    return vinculo.get("profesional", {}).get("S")
