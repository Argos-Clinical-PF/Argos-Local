import hashlib
import hmac
import json
import os
import secrets
from datetime import datetime, timezone
from uuid import UUID, uuid4

import boto3
import jwt
from botocore.exceptions import ClientError
from identidad_cognito import identificar, profesional_activo

MAX_LOTE = 20
MAX_BORRADO = 100
PROPOSITOS = {"FICHA", "LISTADO", "REDACCION"}
PERMISOS_ASINCRONOS = {
    "AUTORIZAR_NOTA": "NOTA_AUTOMATICA",
    "AUTORIZAR_PATRONES": "PATRONES_AUTOMATICOS",
}


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


def profesional_autorizado(ddb, sujeto):
    if isinstance(sujeto, str) and sujeto.startswith("servicio#"):
        if os.getenv("IDENTIDAD_INTERNA_HABILITADA") != "true":
            return None
        profesional = uuid_canonico(sujeto.removeprefix("servicio#"))
        registro = ddb.get_item(TableName=os.environ["TABLA_VINCULOS"],
                                Key={"sujeto": {"S": sujeto}}, ConsistentRead=True).get("Item")
        if registro is None:
            return profesional
        if registro.get("activo", {}).get("BOOL") is True and registro.get("profesional", {}).get("S") == profesional:
            return profesional
        return None
    return profesional_activo(ddb, sujeto)


def autorizar(evento, ddb):
    if os.getenv("IDENTIDAD_INTERNA_HABILITADA") == "true" and evento.get("prueba") == "servicio-argos":
        profesional = uuid_canonico(evento.get("profesional"))
        sujeto = "servicio#" + profesional
        if profesional_autorizado(ddb, sujeto) != profesional:
            raise Rechazo("ACCESO_DENEGADO")
        return profesional, sujeto
    prueba = evento.get("prueba")
    if not isinstance(prueba, str) or len(prueba) > 4096:
        raise Rechazo("ACCESO_DENEGADO")
    try:
        solicitado = uuid_canonico(evento.get("profesional"))
        if os.getenv("COGNITO_EMISOR"):
            sujeto_oidc, vinculo = identificar(prueba, ddb)
            sujeto = uuid_canonico(vinculo)
        else:
            sujeto_oidc = None
            sujeto = autorizar_emisor_sintetico(prueba)
        profesionales = os.getenv("PROFESIONALES")
        if sujeto != solicitado or (profesionales is not None and sujeto not in profesionales.split(",")):
            raise Rechazo("ACCESO_DENEGADO")
        return sujeto, sujeto_oidc
    except jwt.PyJWKClientConnectionError:
        raise Rechazo("BOVEDA_NO_DISPONIBLE") from None
    except (jwt.PyJWTError, Rechazo, AttributeError, TypeError, ValueError):
        raise Rechazo("ACCESO_DENEGADO") from None


def autorizar_emisor_sintetico(prueba):
    if not os.getenv("PROFESIONALES") or os.getenv("TABLA_VINCULOS"):
        raise Rechazo("ACCESO_DENEGADO")
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


def llave_baja(profesional, paciente):
    return {"ambito": {"S": profesional}, "paciente": {"S": paciente}}


def comprobar_baja(ddb, tabla, clave):
    if ddb.get_item(TableName=tabla, Key=clave, ConsistentRead=True).get("Item"):
        raise Rechazo("ACCESO_DENEGADO")


def verificar_borrado(ddb, tabla, tabla_bajas, profesional, ref):
    baja = ddb.get_item(
        TableName=tabla_bajas, Key=llave_baja(profesional, ref[0]), ConsistentRead=True
    ).get("Item")
    if baja:
        if baja.get("version_borrado", {}).get("S") != ref[1]:
            raise Rechazo("ACCESO_DENEGADO")
        return True
    clave = llave(profesional, ref)
    vigente = ddb.query(
        TableName=tabla, ConsistentRead=True, Select="SPECIFIC_ATTRIBUTES", ProjectionExpression="referencia",
        KeyConditionExpression="ambito = :ambito AND referencia = :referencia",
        ExpressionAttributeValues={":ambito": clave["ambito"], ":referencia": clave["referencia"]},
    )
    if not vigente["Items"]:
        raise Rechazo("ACCESO_DENEGADO")
    return False


def borrar(ddb, profesional, evento):
    if set(evento) != {"profesional", "paciente", "token", "prueba", "preparar"} or type(evento["preparar"]) is not bool:
        raise Rechazo("SOLICITUD_INVALIDA")
    tabla = os.environ["TABLA_BOVEDA"]
    tabla_bajas = os.environ["TABLA_BAJAS"]
    ref = referencia(evento)
    marcada = verificar_borrado(ddb, tabla, tabla_bajas, profesional, ref)
    if evento["preparar"]:
        return {}
    if not marcada:
        try:
            ddb.transact_write_items(TransactItems=[
                {"ConditionCheck": {"TableName": tabla, "Key": llave(profesional, ref),
                                    "ConditionExpression": "attribute_exists(referencia)"}},
                {"Put": {"TableName": tabla_bajas,
                         "Item": {**llave_baja(profesional, ref[0]), "version_borrado": {"S": ref[1]},
                                  "fecha": {"S": datetime.now(timezone.utc).isoformat()}},
                         "ConditionExpression": "attribute_not_exists(paciente)"}},
            ])
        except ddb.exceptions.TransactionCanceledException:
            if not verificar_borrado(ddb, tabla, tabla_bajas, profesional, ref):
                raise

    lote = ddb.query(
        TableName=tabla, ConsistentRead=True, Select="SPECIFIC_ATTRIBUTES", ProjectionExpression="ambito, referencia",
        KeyConditionExpression="ambito = :ambito AND begins_with(referencia, :prefijo)",
        ExpressionAttributeValues={":ambito": {"S": profesional}, ":prefijo": {"S": f"{ref[0]}#"}},
        Limit=MAX_BORRADO + 1,
    )
    if lote["Items"]:
        ddb.transact_write_items(TransactItems=[
            {"Delete": {"TableName": tabla, "Key": clave}} for clave in lote["Items"][:MAX_BORRADO]
        ])
    if len(lote["Items"]) > MAX_BORRADO or lote.get("LastEvaluatedKey"):
        # El marcador impide nuevas escrituras. El próximo intento continúa con el lote restante.
        raise Rechazo("BOVEDA_BORRADO_EN_CURSO")
    return {}


def guardar_si_activo(ddb, tabla, item, tabla_bajas, clave_baja):
    guardar_item = {"TableName": tabla, "Item": item,
                    "ConditionExpression": "attribute_not_exists(referencia)"}
    try:
        if tabla_bajas:
            ddb.transact_write_items(TransactItems=[
                {"ConditionCheck": {"TableName": tabla_bajas, "Key": clave_baja,
                                    "ConditionExpression": "attribute_not_exists(paciente)"}},
                {"Put": guardar_item},
            ])
        else:
            ddb.put_item(**guardar_item)
        return True
    except ddb.exceptions.ConditionalCheckFailedException:
        return False
    except ddb.exceptions.TransactionCanceledException as error:
        motivos = error.response.get("CancellationReasons", [])
        if len(motivos) != 2:
            raise
        if motivos[0].get("Code") == "ConditionalCheckFailed":
            raise Rechazo("ACCESO_DENEGADO") from None
        if motivos[1].get("Code") == "ConditionalCheckFailed":
            comprobar_baja(ddb, tabla_bajas, clave_baja)
            return False
        raise

def contexto(profesional, ref):
    vinculo = json.dumps([profesional, *ref], separators=(",", ":")).encode()
    return {
        "entorno": os.getenv("ENTORNO_BOVEDA", "piloto-tokenizacion"),
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
            "expira": {"N": str(int(ahora.timestamp()) + int(os.getenv("AUDITORIA_DIAS", "14")) * 86400)},
        },
    )


def guardar(ddb, kms, profesional, evento):
    ref = referencia(evento)
    alias = evento.get("alias")
    if not isinstance(alias, str) or not 1 <= len(alias) <= 100 or alias.strip() != alias:
        raise Rechazo("SOLICITUD_INVALIDA")
    tabla_bajas = os.getenv("TABLA_BAJAS")
    clave_baja = llave_baja(profesional, ref[0])
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
    item = {**clave, "cifrado": {"B": cifrado}, "huella": {"S": huella}}
    if not guardar_si_activo(ddb, os.environ["TABLA_BOVEDA"], item, tabla_bajas, clave_baja):
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
    tabla_bajas = os.getenv("TABLA_BAJAS")
    solicitud = {tabla: {"Keys": [llave(profesional, ref) for ref in refs], "ConsistentRead": True}}
    if tabla_bajas:
        pacientes = dict.fromkeys(ref[0] for ref in refs)
        solicitud[tabla_bajas] = {"Keys": [llave_baja(profesional, id_paciente) for id_paciente in pacientes],
                                  "ConsistentRead": True}
    respuesta = ddb.batch_get_item(RequestItems=solicitud)
    if respuesta.get("UnprocessedKeys"):
        raise Rechazo("BOVEDA_NO_DISPONIBLE")
    if tabla_bajas and respuesta["Responses"].get(tabla_bajas):
        raise Rechazo("ACCESO_DENEGADO")
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


def vinculo_permiso(evento, profesional):
    registros = evento.get("registros")
    if not isinstance(registros, list) or len(registros) != 1:
        raise Rechazo("ACCESO_DENEGADO")
    return [profesional, uuid_canonico(evento.get("sesion")), *referencia(registros[0])]


def emitir_permiso(ddb, profesional, sujeto, evento, proposito):
    if not sujeto or not os.getenv("TABLA_PERMISOS_NOTA"):
        raise Rechazo("ACCESO_DENEGADO")
    valores = vinculo_permiso(evento, profesional)
    ref = tuple(valores[2:])
    tabla_bajas = os.getenv("TABLA_BAJAS")
    if tabla_bajas:
        comprobar_baja(ddb, tabla_bajas, llave_baja(profesional, ref[0]))
    if not ddb.get_item(TableName=os.environ["TABLA_BOVEDA"], Key=llave(profesional, ref),
                        ProjectionExpression="referencia", ConsistentRead=True).get("Item"):
        raise Rechazo("ACCESO_DENEGADO")
    permiso = secrets.token_urlsafe(32)
    ddb.put_item(TableName=os.environ["TABLA_PERMISOS_NOTA"], Item={
        "huella": {"S": hashlib.sha256(permiso.encode()).hexdigest()},
        "vinculo": {"S": json.dumps(valores)}, "sujeto": {"S": sujeto},
        "proposito": {"S": proposito},
        "expira": {"N": str(int(datetime.now(timezone.utc).timestamp()) + 86400)},
    }, ConditionExpression="attribute_not_exists(huella)")
    return {"permiso": permiso}


def autorizar_permiso(ddb, evento):
    permiso = evento.get("permiso")
    if not isinstance(permiso, str) or len(permiso) != 43 or not os.getenv("TABLA_PERMISOS_NOTA"):
        raise Rechazo("ACCESO_DENEGADO")
    profesional = uuid_canonico(evento.get("profesional"))
    registro = ddb.get_item(TableName=os.environ["TABLA_PERMISOS_NOTA"],
                            Key={"huella": {"S": hashlib.sha256(permiso.encode()).hexdigest()}},
                            ConsistentRead=True).get("Item")
    if not registro or int(registro["expira"]["N"]) <= datetime.now(timezone.utc).timestamp():
        raise Rechazo("ACCESO_DENEGADO")
    if (registro.get("proposito", {"S": "NOTA_AUTOMATICA"})["S"] != evento["proposito"]
            or json.loads(registro["vinculo"]["S"]) != vinculo_permiso(evento, profesional)
            or profesional_autorizado(ddb, registro["sujeto"]["S"]) != profesional):
        raise Rechazo("ACCESO_DENEGADO")
    return profesional


def handler(evento, _contexto):
    modo = os.environ["OPERACION"]
    ddb = boto3.client("dynamodb")
    profesional = None
    operacion = modo
    try:
        if not isinstance(evento, dict):
            raise Rechazo("SOLICITUD_INVALIDA")
        proposito = evento.get("proposito")
        if modo == "resolver" and proposito in PERMISOS_ASINCRONOS.values():
            profesional = autorizar_permiso(ddb, evento)
            operacion = proposito
            datos = resolver(ddb, boto3.client("kms"), profesional, {**evento, "proposito": "REDACCION"})
            cantidad = 1
        elif modo == "resolver" and isinstance(proposito, str) and proposito in PERMISOS_ASINCRONOS:
            profesional, sujeto = autorizar(evento, ddb)
            operacion = proposito
            datos = emitir_permiso(ddb, profesional, sujeto, evento, PERMISOS_ASINCRONOS[proposito])
            cantidad = 1
        elif modo == "guardar":
            profesional, _ = autorizar(evento, ddb)
            datos = guardar(ddb, boto3.client("kms"), profesional, evento)
            cantidad = 1
        elif modo == "borrar":
            profesional, _ = autorizar(evento, ddb)
            operacion = "PREPARAR_BORRADO" if evento.get("preparar") is True else "BORRAR"
            datos = borrar(ddb, profesional, evento)
            cantidad = 1
        elif modo == "resolver":
            profesional, _ = autorizar(evento, ddb)
            datos = resolver(ddb, boto3.client("kms"), profesional, evento)
            cantidad = len(datos["alias"])
            operacion = evento["proposito"]
        else:
            raise Rechazo("BOVEDA_NO_DISPONIBLE")
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
