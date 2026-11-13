import hashlib
import hmac
import json
import os
from datetime import datetime, timezone
from uuid import UUID, uuid4

import boto3
import jwt
from botocore.exceptions import ClientError
from identidad_cognito import identificar

MAX_LOTE = 20
PROPOSITOS = {"FICHA", "LISTADO", "REDACCION"}


class Rechazo(Exception):
    def __init__(self, codigo):
        self.codigo = codigo


def uuid_canonico(valor):
    if not isinstance(valor, str):
        raise Rechazo("SOLICITUD_INVALIDA")
    try:
        return str(UUID(valor))
    except ValueError:
        raise Rechazo("SOLICITUD_INVALIDA") from None


def autorizar(evento):
    prueba = evento.get("prueba")
    if not isinstance(prueba, str) or len(prueba) > 4096:
        raise Rechazo("ACCESO_DENEGADO")
    try:
        solicitado = uuid_canonico(evento.get("profesional"))
        if os.getenv("COGNITO_EMISOR"):
            sujeto = uuid_canonico(identificar(prueba))
        else:
            sujeto = autorizar_emisor_sintetico(prueba)
        if sujeto != solicitado or sujeto not in os.environ["PROFESIONALES"].split(","):
            raise Rechazo("ACCESO_DENEGADO")
        return sujeto
    except jwt.PyJWKClientConnectionError:
        raise Rechazo("BOVEDA_NO_DISPONIBLE") from None
    except (jwt.PyJWTError, Rechazo, AttributeError, TypeError, ValueError):
        raise Rechazo("ACCESO_DENEGADO") from None


def autorizar_emisor_sintetico(prueba):
    datos = jwt.decode(
        prueba,
        os.environ["CLAVE_PUBLICA"],
        algorithms=["RS256"],
        issuer=os.environ["EMISOR"],
        audience="argos-boveda-alias",
        options={"require": ["sub", "iat", "nbf", "exp", "iss", "aud"]},
    )
    if (
        datos.get("tipo") != "acceso"
        or datos["exp"] - datos["iat"] > 900
        or datos["iat"] > datos["nbf"]
        or datos["nbf"] >= datos["exp"]
    ):
        raise Rechazo("ACCESO_DENEGADO")
    return uuid_canonico(datos["sub"])


def referencia(dato):
    if not isinstance(dato, dict):
        raise Rechazo("SOLICITUD_INVALIDA")
    return uuid_canonico(dato.get("paciente")), uuid_canonico(dato.get("token"))


def llave(profesional, ref):
    paciente, token = ref
    return {"ambito": {"S": profesional}, "referencia": {"S": f"{paciente}#{token}"}}


def contexto(profesional, ref):
    vinculo = json.dumps([profesional, *ref], separators=(",", ":")).encode()
    return {
        "entorno": "piloto-tokenizacion",
        "dato": "alias-paciente",
        "vinculo": hashlib.sha256(vinculo).hexdigest(),
    }


def auditar(ddb, profesional, operacion, resultado, cantidad):
    ahora = datetime.now(timezone.utc)
    ddb.put_item(
        TableName=os.environ["TABLA_AUDITORIA"],
        Item={
            "evento": {"S": str(uuid4())},
            "profesional": {"S": profesional or "sin-verificar"},
            "operacion": {"S": operacion},
            "resultado": {"S": resultado},
            "cantidad": {"N": str(cantidad)},
            "fecha": {"S": ahora.isoformat()},
            "expira": {"N": str(int(ahora.timestamp()) + 14 * 86400)},
        },
    )


def guardar(ddb, kms, profesional, evento):
    ref = referencia(evento)
    alias = evento.get("alias")
    if not isinstance(alias, str) or not 1 <= len(alias) <= 100 or alias.strip() != alias:
        raise Rechazo("SOLICITUD_INVALIDA")
    entrada = json.dumps(
        ["alias-paciente-v1", profesional, alias], ensure_ascii=False, separators=(",", ":")
    ).encode()
    huella = kms.generate_mac(
        KeyId=os.environ["CLAVE_HUELLA"], MacAlgorithm="HMAC_SHA_256", Message=entrada
    )["Mac"].hex()
    clave = llave(profesional, ref)
    cifrado = kms.encrypt(
        KeyId=os.environ["CLAVE_CIFRADO"], Plaintext=alias.encode(),
        EncryptionContext=contexto(profesional, ref),
    )["CiphertextBlob"]
    try:
        ddb.put_item(
            TableName=os.environ["TABLA_BOVEDA"],
            Item={**clave, "cifrado": {"B": cifrado}, "huella": {"S": huella}},
            ConditionExpression="attribute_not_exists(referencia)",
        )
    except ddb.exceptions.ConditionalCheckFailedException:
        previo = ddb.get_item(
            TableName=os.environ["TABLA_BOVEDA"], Key=clave, ConsistentRead=True
        ).get("Item")
        if not previo or not hmac.compare_digest(previo["huella"]["S"], huella):
            raise Rechazo("OPERACION_EN_CONFLICTO") from None
    return {"huella": huella}


def resolver(ddb, kms, profesional, evento):
    registros = evento.get("registros")
    if not isinstance(registros, list) or not 1 <= len(registros) <= MAX_LOTE:
        raise Rechazo("SOLICITUD_INVALIDA")
    proposito = evento.get("proposito")
    if not isinstance(proposito, str) or proposito not in PROPOSITOS:
        raise Rechazo("SOLICITUD_INVALIDA")
    refs = [referencia(registro) for registro in registros]
    if len(refs) != len(set(refs)):
        raise Rechazo("SOLICITUD_INVALIDA")
    tabla = os.environ["TABLA_BOVEDA"]
    respuesta = ddb.batch_get_item(
        RequestItems={tabla: {"Keys": [llave(profesional, ref) for ref in refs], "ConsistentRead": True}}
    )
    if respuesta.get("UnprocessedKeys"):
        raise Rechazo("BOVEDA_NO_DISPONIBLE")
    encontrados = {item["referencia"]["S"]: item for item in respuesta["Responses"].get(tabla, [])}
    if len(encontrados) != len(refs):
        raise Rechazo("ACCESO_DENEGADO")
    return {"alias": {
        ref[1]: kms.decrypt(
            KeyId=os.environ["CLAVE_CIFRADO"],
            CiphertextBlob=encontrados[f"{ref[0]}#{ref[1]}"]["cifrado"]["B"],
            EncryptionContext=contexto(profesional, ref),
        )["Plaintext"].decode()
        for ref in refs
    }}


def handler(evento, _contexto):
    modo = os.environ["OPERACION"]
    ddb = boto3.client("dynamodb")
    kms = boto3.client("kms")
    profesional = None
    operacion = modo
    try:
        if not isinstance(evento, dict):
            raise Rechazo("SOLICITUD_INVALIDA")
        profesional = autorizar(evento)
        if modo == "guardar":
            datos = guardar(ddb, kms, profesional, evento)
            cantidad = 1
        else:
            datos = resolver(ddb, kms, profesional, evento)
            cantidad = len(datos["alias"])
            operacion = evento["proposito"]
        auditar(ddb, profesional, operacion, "AUTORIZADO", cantidad)
        return {"codigo": "OK", **datos}
    except Rechazo as error:
        try:
            auditar(ddb, profesional, operacion, error.codigo, 0)
        except ClientError:
            return {"codigo": "BOVEDA_NO_DISPONIBLE"}
        return {"codigo": error.codigo}
    except ClientError:
        return {"codigo": "BOVEDA_NO_DISPONIBLE"}
