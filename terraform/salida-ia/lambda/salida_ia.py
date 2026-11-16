import base64
import json
import os
import re
import time
from functools import lru_cache
from urllib.error import HTTPError, URLError
from urllib.request import HTTPRedirectHandler, Request, build_opener
from uuid import UUID

from botocore.exceptions import ClientError, ConnectionError, ReadTimeoutError
from botocore.config import Config
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

MAX_BYTES = 256_000
VERSION_ANTHROPIC = "bedrock-2023-05-31"
CAMPOS = {"max_tokens", "system", "messages", "output_config", "tools", "tool_choice", "thinking"}
PERFILES = {"clinica": "MODELO_CLINICA", "temas": "MODELO_TEMAS"}
PROPOSITOS = {
    "clinica": {"GENERAL", "NOTA", "EVOLUCION", "COPILOTO_PACIENTE", "COPILOTO_SESION"},
    "temas": {"TEMAS"},
}
AUTORIZADOR = "https://argosclinical.online/api/interno/ia/autorizar"
PARAMETRO_FIRMA = "/argos/salida-ia/firma-autorizador"
CAMPOS_BLOQUE = {
    "text": {"type", "text", "cache_control"},
    "tool_result": {"type", "tool_use_id", "content", "is_error", "cache_control"},
    "tool_use": {"type", "id", "name", "input", "cache_control"},
}
DIRECTOS = re.compile(
    r"[\w.%+-]+@[\w.-]+\.[A-Za-z]{2,}"
    r"|\b(?:https?://|www\.)\S+"
    r"|\b[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}\b"
    r"|\b(?:DNI|documento|CUIL|CUIT)\s*(?:n(?:ro)?[.°º]?|:)?\s*[0-9.\-]{7,}\b"
    r"|\+\d(?:[ .()\-]*\d){7,14}(?![\d .()\-]*\d)"
    r"|(?<![A-Za-z0-9+/])[A-Za-z0-9+/]{256,}={0,2}(?![A-Za-z0-9+/])",
    re.IGNORECASE,
)


def rechazo(codigo, estado):
    return {"codigo": codigo, "estado": estado}


def hay_identificadores(valor):
    if isinstance(valor, str):
        return DIRECTOS.search(valor) is not None
    if isinstance(valor, list):
        return any(hay_identificadores(item) for item in valor)
    if isinstance(valor, dict):
        return any(hay_identificadores(k) or hay_identificadores(v) for k, v in valor.items())
    return False


def bloque_permitido(bloque, tipos):
    if not isinstance(bloque, dict):
        return False
    tipo = bloque.get("type")
    if not isinstance(tipo, str) or tipo not in tipos or set(bloque) - CAMPOS_BLOQUE[tipo]:
        return False
    if "cache_control" in bloque and bloque["cache_control"] != {"type": "ephemeral"}:
        return False
    if tipo == "text":
        return isinstance(bloque.get("text"), str)
    if tipo == "tool_use":
        return (isinstance(bloque.get("id"), str) and isinstance(bloque.get("name"), str)
                and isinstance(bloque.get("input"), dict))
    return isinstance(bloque.get("tool_use_id"), str) and isinstance(bloque.get("content"), str)


def mensaje_permitido(mensaje):
    if not isinstance(mensaje, dict) or set(mensaje) != {"role", "content"}:
        return False
    rol, contenido = mensaje["role"], mensaje["content"]
    if rol not in ("user", "assistant"):
        return False
    tipos = {"text", "tool_use"} if rol == "assistant" else {"text", "tool_result"}
    return isinstance(contenido, str) or (isinstance(contenido, list)
                                          and all(bloque_permitido(bloque, tipos) for bloque in contenido))


def uuid_canonico(valor):
    try:
        return isinstance(valor, str) and str(UUID(valor)) == valor
    except ValueError:
        return False


def contexto_permitido(contexto, perfil):
    if (not isinstance(contexto, dict) or set(contexto) - {
            "proposito", "profesional", "paciente", "sesion", "lecturas", "alcancesEvidencia"}
            or not isinstance(contexto.get("proposito"), str) or contexto["proposito"] not in PROPOSITOS[perfil]
            or not uuid_canonico(contexto.get("profesional"))):
        return False
    if any(campo in contexto and not uuid_canonico(contexto[campo]) for campo in ("paciente", "sesion")):
        return False
    if contexto["proposito"] == "NOTA":
        alcances = contexto.get("alcancesEvidencia")
        if (not isinstance(alcances, list) or len(alcances) > 2
                or any(alcance not in ("TRANSCRIPCION_LOCAL", "ANALISIS_EMOCIONAL_VIDEO") for alcance in alcances)):
            return False
    elif "alcancesEvidencia" in contexto:
        return False
    lecturas = contexto.get("lecturas", [])
    return isinstance(lecturas, list) and len(lecturas) <= 100 and all(uuid_canonico(id) for id in lecturas)


def armar_solicitud(evento):
    if (not isinstance(evento, dict) or set(evento) != {"version", "perfil", "contexto", "cuerpo"}
            or type(evento["version"]) is not int or evento["version"] != 2
            or not isinstance(evento["perfil"], str) or evento["perfil"] not in PERFILES
            or not contexto_permitido(evento["contexto"], evento["perfil"])):
        return None, rechazo("SOLICITUD_INVALIDA", 400)

    cuerpo = evento["cuerpo"]
    if not isinstance(cuerpo, dict) or set(cuerpo) - CAMPOS:
        return None, rechazo("SOLICITUD_INVALIDA", 400)
    max_tokens = cuerpo.get("max_tokens")
    if (type(max_tokens) is not int or not 1 <= max_tokens <= 4000
            or not isinstance(cuerpo.get("system"), list)
            or not isinstance(cuerpo.get("messages"), list) or not cuerpo["messages"]
            or not all(bloque_permitido(b, {"text"}) for b in cuerpo["system"])
            or not all(mensaje_permitido(m) for m in cuerpo["messages"])):
        return None, rechazo("SOLICITUD_INVALIDA", 400)

    try:
        solicitud = json.dumps({**cuerpo, "anthropic_version": VERSION_ANTHROPIC},
                               ensure_ascii=False, allow_nan=False, separators=(",", ":")).encode()
        if len(solicitud) > MAX_BYTES:
            return None, rechazo("CONTEXTO_EXTENSO", 413)
        # El backend ya redacta el contenido clínico. Esta comprobación independiente corta
        # envíos con identificadores directos reconocibles y deja al backend conservar las citas.
        if hay_identificadores(cuerpo):
            return None, rechazo("IDENTIFICADOR_DETECTADO", 422)
    except (RecursionError, UnicodeError, ValueError):
        return None, rechazo("SOLICITUD_INVALIDA", 400)
    return solicitud, None


def invocar(evento, cliente, modelos, autorizar):
    solicitud, error = armar_solicitud(evento)
    if error:
        return error
    permiso = autorizar(evento["contexto"])
    if permiso != 204:
        if permiso == 403:
            return rechazo("CONSENTIMIENTO_DENEGADO", 403)
        return rechazo("AUTORIZADOR_NO_DISPONIBLE", 503)
    try:
        respuesta = cliente.invoke_model(modelId=modelos[PERFILES[evento["perfil"]]],
                                         contentType="application/json", accept="application/json",
                                         body=solicitud)
        salida = json.loads(respuesta["body"].read())
        if not isinstance(salida, dict) or not isinstance(salida.get("content"), list):
            return rechazo("RESPUESTA_INVALIDA", 502)
        return {"codigo": "OK", "datos": salida}
    except ClientError as error:
        estado = error.response.get("ResponseMetadata", {}).get("HTTPStatusCode", 502)
        codigo = error.response.get("Error", {}).get("Code")
        if codigo in {"ThrottlingException", "ServiceQuotaExceededException"}:
            return rechazo("CUOTA", 429)
        if codigo == "AccessDeniedException":
            return rechazo("ACCESO_DENEGADO", 403)
        return rechazo("PROVEEDOR_ERROR", estado)
    except ReadTimeoutError:
        return rechazo("PROVEEDOR_TIMEOUT", 504)
    except (ConnectionError, UnicodeError, ValueError):
        return rechazo("PROVEEDOR_ERROR", 502)


@lru_cache(maxsize=1)
def cliente_bedrock():
    import boto3

    return boto3.client("bedrock-runtime", config=Config(connect_timeout=5, read_timeout=120,
                                                        retries={"total_max_attempts": 1}))


@lru_cache(maxsize=1)
def clave_firma():
    import boto3

    ssm = boto3.client("ssm", config=Config(connect_timeout=2, read_timeout=2, retries={"total_max_attempts": 1}))
    valor = ssm.get_parameter(Name=PARAMETRO_FIRMA, WithDecryption=True)["Parameter"]["Value"]
    return Ed25519PrivateKey.from_private_bytes(base64.urlsafe_b64decode(valor + "="))


class SinRedireccion(HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def autorizar_contexto(contexto, cargar_clave=clave_firma, abrir=None):
    try:
        cuerpo = json.dumps(contexto, separators=(",", ":")).encode()
        fecha = str(int(time.time()))
        firma = cargar_clave().sign(f"argos-salida-ia-v2\n{fecha}\n".encode("ascii") + cuerpo)
        solicitud = Request(AUTORIZADOR, data=cuerpo, headers={
            "Content-Type": "application/json",
            "X-Argos-Fecha": fecha,
            "X-Argos-Firma": base64.urlsafe_b64encode(firma).decode().rstrip("="),
        }, method="POST")
        abrir = abrir or build_opener(SinRedireccion()).open
        with abrir(solicitud, timeout=3) as respuesta:
            return respuesta.status
    except HTTPError as error:
        error.close()
        return error.code
    except (URLError, TimeoutError, ValueError, ClientError, ConnectionError, ReadTimeoutError):
        return 503


def handler(evento, _contexto):
    return invocar(evento, cliente_bedrock(), {clave: os.environ[clave] for clave in PERFILES.values()}, autorizar_contexto)
