import argparse
import json
import os
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path
from urllib.parse import unquote
from uuid import uuid4

import boto3
import jwt
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from moto import mock_aws

import sys

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "terraform/piloto-tokenizacion/lambda"))
from boveda_alias import handler


def crear_tabla(ddb, tabla, claves):
    ddb.create_table(
        TableName=tabla,
        BillingMode="PAY_PER_REQUEST",
        AttributeDefinitions=[{"AttributeName": k, "AttributeType": "S"} for k in claves],
        KeySchema=[
            {"AttributeName": k, "KeyType": tipo}
            for k, tipo in zip(claves, ("HASH", "RANGE"))
        ],
    )


class TransporteLocal(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_POST(self):
        rutas = {
            f"/2015-03-31/functions/argos-piloto-boveda-{modo}:piloto/invocations": modo
            for modo in ("guardar", "resolver")
        }
        modo = rutas.get(unquote(self.path))
        if modo is None:
            self.send_error(404)
            return
        longitud = int(self.headers.get("Content-Length", "0"))
        if not 1 <= longitud <= 16_384:
            self.send_error(400)
            return
        try:
            evento = json.loads(self.rfile.read(longitud))
        except (ValueError, UnicodeError):
            self.send_error(400)
            return
        os.environ["OPERACION"] = modo
        cuerpo = json.dumps(handler(evento, None)).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(cuerpo)))
        self.end_headers()
        self.wfile.write(cuerpo)


EMISOR = "argos-emisor-sintetico"


def emitir_acceso(salida, endpoint=None):
    privada = rsa.generate_private_key(public_exponent=65537, key_size=2048)
    publica = privada.public_key().public_bytes(
        serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
    ).decode()
    profesionales = [str(uuid4()), str(uuid4())]

    def prueba(profesional, **ajustes):
        ahora = int(datetime.now(timezone.utc).timestamp())
        datos = {"sub": profesional, "iat": ahora, "nbf": ahora, "exp": ahora + 900,
                 "iss": EMISOR, "aud": "argos-boveda-alias", "tipo": "acceso"}
        return jwt.encode({**datos, **ajustes}, privada, algorithm="RS256")

    datos = {
        "endpoint": endpoint,
        "clavePublica": publica,
        "profesionales": profesionales,
        "pruebas": [prueba(id) for id in profesionales],
        "audienciaIncorrecta": prueba(profesionales[0], aud="otra-aplicacion"),
        "expirada": prueba(profesionales[0], exp=1, iat=0, nbf=0),
    }
    fd = os.open(salida, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    with os.fdopen(fd, "w") as archivo:
        json.dump(datos, archivo)
    return datos


def ejecutar(puerto, salida):
    with mock_aws(), HTTPServer(("127.0.0.1", puerto), TransporteLocal) as servidor:
        os.environ["AWS_DEFAULT_REGION"] = "us-east-1"
        ddb = boto3.client("dynamodb")
        kms = boto3.client("kms")
        crear_tabla(ddb, "boveda", ["ambito", "referencia"])
        crear_tabla(ddb, "auditoria", ["evento"])
        datos = emitir_acceso(salida, f"http://127.0.0.1:{servidor.server_port}")
        os.environ.update({
            "CLAVE_PUBLICA": datos["clavePublica"], "EMISOR": EMISOR,
            "PROFESIONALES": ",".join(datos["profesionales"]),
            "CLAVE_CIFRADO": kms.create_key()["KeyMetadata"]["KeyId"],
            "CLAVE_HUELLA": kms.create_key(KeySpec="HMAC_256", KeyUsage="GENERATE_VERIFY_MAC")["KeyMetadata"]["KeyId"],
            "TABLA_BOVEDA": "boveda", "TABLA_AUDITORIA": "auditoria",
        })

        try:
            servidor.serve_forever()
        finally:
            salida.unlink(missing_ok=True)


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--puerto", type=int, default=0)
    parser.add_argument("--acceso", type=Path, required=True)
    parser.add_argument("--solo-emisor", action="store_true")
    args = parser.parse_args()
    if args.solo_emisor:
        emitir_acceso(args.acceso)
    else:
        ejecutar(args.puerto, args.acceso)
