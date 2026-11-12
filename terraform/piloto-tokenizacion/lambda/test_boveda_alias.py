import json
import os
import unittest
from datetime import datetime, timezone
from unittest.mock import patch
from uuid import uuid4

import boto3
import jwt
from botocore.exceptions import ClientError
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from moto import mock_aws

from boveda_alias import handler, llave


class BovedaAliasTest(unittest.TestCase):
    def setUp(self):
        aws = mock_aws()
        aws.start()
        self.addCleanup(aws.stop)
        entorno = patch.dict(os.environ, {
            "AWS_DEFAULT_REGION": "us-east-1",
            "TABLA_BOVEDA": "boveda",
            "TABLA_AUDITORIA": "auditoria",
            "EMISOR": "emisor-pruebas",
        })
        entorno.start()
        self.addCleanup(entorno.stop)
        self.ddb = boto3.client("dynamodb")
        for tabla, campos in (("boveda", ["ambito", "referencia"]), ("auditoria", ["evento"])):
            self.ddb.create_table(
                TableName=tabla,
                BillingMode="PAY_PER_REQUEST",
                AttributeDefinitions=[{"AttributeName": c, "AttributeType": "S"} for c in campos],
                KeySchema=[{"AttributeName": c, "KeyType": t} for c, t in zip(campos, ("HASH", "RANGE"))],
            )
        kms = boto3.client("kms")
        os.environ["CLAVE_CIFRADO"] = kms.create_key()["KeyMetadata"]["KeyId"]
        os.environ["CLAVE_HUELLA"] = kms.create_key(
            KeySpec="HMAC_256", KeyUsage="GENERATE_VERIFY_MAC"
        )["KeyMetadata"]["KeyId"]
        self.privada = rsa.generate_private_key(public_exponent=65537, key_size=2048)
        os.environ["CLAVE_PUBLICA"] = self.privada.public_key().public_bytes(
            serialization.Encoding.PEM, serialization.PublicFormat.SubjectPublicKeyInfo
        ).decode()
        self.profesional, self.ajeno = str(uuid4()), str(uuid4())
        os.environ["PROFESIONALES"] = f"{self.profesional},{self.ajeno}"
        self.ref = {"paciente": str(uuid4()), "token": str(uuid4())}
        self.alias = "Identidad ficticia Ámbar"

    def prueba(self, sujeto, **ajustes):
        ahora = int(datetime.now(timezone.utc).timestamp())
        datos = {"sub": sujeto, "iss": "emisor-pruebas", "aud": "argos-boveda-alias",
                 "iat": ahora, "nbf": ahora, "exp": ahora + 600, "tipo": "acceso"}
        return jwt.encode({**datos, **ajustes}, self.privada, algorithm="RS256")

    def invocar(self, modo, **cuerpo):
        evento = {"profesional": self.profesional, "prueba": self.prueba(self.profesional), **cuerpo}
        with patch.dict(os.environ, {"OPERACION": modo}):
            return handler(evento, None)

    def guardar(self, **cambios):
        return self.invocar("guardar", **{**self.ref, "alias": self.alias, **cambios})

    def resolver(self, **cambios):
        return self.invocar("resolver", **{"proposito": "FICHA", "registros": [self.ref], **cambios})

    def test_idempotencia_y_cifrado(self):
        creada = self.guardar()
        self.assertEqual(creada["codigo"], "OK")
        self.assertEqual(creada, self.guardar())
        self.assertEqual(self.guardar(alias="Otra identidad")["codigo"], "OPERACION_EN_CONFLICTO")
        fila = self.ddb.scan(TableName="boveda")["Items"]
        self.assertEqual(len(fila), 1)
        self.assertNotIn(self.alias.encode(), fila[0]["cifrado"]["B"])
        self.assertEqual(self.resolver()["alias"][self.ref["token"]], self.alias)
        auditoria = json.dumps(self.ddb.scan(TableName="auditoria")["Items"], ensure_ascii=False)
        self.assertNotIn(self.alias, auditoria)
        self.assertNotIn(self.ref["token"], auditoria)

    def test_aislamiento_y_lotes(self):
        self.assertEqual(self.guardar()["codigo"], "OK")
        self.assertEqual(self.resolver(profesional=self.ajeno, prueba=self.prueba(self.ajeno)),
                         {"codigo": "ACCESO_DENEGADO"})
        self.assertEqual(self.resolver(profesional=self.ajeno), {"codigo": "ACCESO_DENEGADO"})
        self.assertEqual(self.resolver(prueba=self.prueba(self.profesional, aud="otro")),
                         {"codigo": "ACCESO_DENEGADO"})
        self.assertEqual(self.resolver(prueba=None), {"codigo": "ACCESO_DENEGADO"})
        ajeno = {"paciente": str(uuid4()), "token": str(uuid4())}
        self.assertEqual(self.resolver(registros=[self.ref, ajeno]), {"codigo": "ACCESO_DENEGADO"})
        self.assertEqual(self.resolver(registros=[self.ref] * 21), {"codigo": "SOLICITUD_INVALIDA"})
        self.assertEqual(self.resolver(proposito=[]), {"codigo": "SOLICITUD_INVALIDA"})

    def test_contexto_criptografico_y_auditoria(self):
        self.assertEqual(self.guardar()["codigo"], "OK")
        origen = llave(self.profesional, (self.ref["paciente"], self.ref["token"]))
        copia = {"paciente": self.ref["paciente"], "token": str(uuid4())}
        destino = llave(self.profesional, (copia["paciente"], copia["token"]))
        fila = self.ddb.get_item(TableName="boveda", Key=origen)["Item"]
        self.ddb.put_item(TableName="boveda", Item={**fila, **destino})
        self.assertEqual(self.resolver(registros=[copia]), {"codigo": "BOVEDA_NO_DISPONIBLE"})
        error = ClientError({"Error": {"Code": "AccessDeniedException"}}, "PutItem")
        with patch("boveda_alias.auditar", side_effect=error):
            self.assertEqual(self.resolver(), {"codigo": "BOVEDA_NO_DISPONIBLE"})
