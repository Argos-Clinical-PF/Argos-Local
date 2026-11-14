import hashlib
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

    def test_cognito_requiere_acceso_del_cliente_y_sujeto_vinculado(self):
        emisor = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_Validacion"
        audiencia = "https://argosclinical.online/recursos/boveda-validacion"
        alcance = audiencia + "/alias"
        sujeto = str(uuid4())
        ahora = int(datetime.now(timezone.utc).timestamp())
        datos = {"sub": sujeto, "iss": emisor, "aud": audiencia, "iat": ahora, "exp": ahora + 300,
                 "client_id": "cliente-validacion", "token_use": "access", "scope": alcance}

        def token(**ajustes):
            return jwt.encode({**datos, **ajustes}, self.privada, algorithm="RS256", headers={"kid": "llave-1"})

        with patch.dict(os.environ, {"COGNITO_EMISOR": emisor, "COGNITO_AUDIENCIA": audiencia,
                                    "COGNITO_CLIENTE": "cliente-validacion", "COGNITO_ALCANCE": alcance,
                                    "COGNITO_VINCULOS": json.dumps({sujeto: self.profesional})}), \
                patch("identidad_cognito.claves") as proveedor:
            proveedor.return_value.get_signing_key_from_jwt.return_value.key = self.privada.public_key()
            self.assertEqual(self.guardar(prueba=token())["codigo"], "OK")
            self.assertEqual(self.resolver(prueba=token())["alias"][self.ref["token"]], self.alias)
            sin_audiencia = jwt.encode({k: v for k, v in datos.items() if k != "aud"}, self.privada, algorithm="RS256")
            self.assertEqual(self.resolver(prueba=sin_audiencia)["codigo"], "OK")
            for ajustes in ({"sub": self.ajeno}, {"aud": "otra"}, {"client_id": "otro"}, {"scope": "openid"},
                            {"token_use": "id"}, {"exp": ahora - 1}, {"iss": "otro"}):
                with self.subTest(ajustes=ajustes):
                    self.assertEqual(self.resolver(prueba=token(**ajustes)), {"codigo": "ACCESO_DENEGADO"})
            self.assertEqual(self.resolver(prueba=token(), profesional=self.ajeno), {"codigo": "ACCESO_DENEGADO"})
            self.assertEqual(self.resolver(prueba=self.prueba(self.profesional)), {"codigo": "ACCESO_DENEGADO"})
            with patch.dict(os.environ, {"COGNITO_VINCULOS": "{}"}):
                self.assertEqual(self.resolver(prueba=token()), {"codigo": "ACCESO_DENEGADO"})
            proveedor.return_value.get_signing_key_from_jwt.side_effect = jwt.PyJWKClientConnectionError("sin red")
            self.assertEqual(self.resolver(prueba=token()), {"codigo": "BOVEDA_NO_DISPONIBLE"})

    def test_revocacion_lee_el_vinculo_vigente_antes_de_cada_resolucion(self):
        self.ddb.create_table(
            TableName="vinculos", BillingMode="PAY_PER_REQUEST",
            AttributeDefinitions=[{"AttributeName": "sujeto", "AttributeType": "S"}],
            KeySchema=[{"AttributeName": "sujeto", "KeyType": "HASH"}],
        )
        emisor = "https://cognito-idp.us-east-1.amazonaws.com/us-east-1_Validacion"
        audiencia = "https://argosclinical.online/recursos/boveda-validacion"
        sujeto = str(uuid4())
        ahora = int(datetime.now(timezone.utc).timestamp())
        jwt_realista = jwt.encode({"sub": sujeto, "iss": emisor, "iat": ahora, "exp": ahora + 300,
                                    "client_id": "cliente-validacion", "token_use": "access", "scope": audiencia + "/alias"},
                                   self.privada, algorithm="RS256")
        item = {"sujeto": {"S": sujeto}, "profesional": {"S": self.profesional}, "activo": {"BOOL": True}}
        self.ddb.put_item(TableName="vinculos", Item=item)
        self.ddb.create_table(
            TableName="permisos", BillingMode="PAY_PER_REQUEST",
            AttributeDefinitions=[{"AttributeName": "huella", "AttributeType": "S"}],
            KeySchema=[{"AttributeName": "huella", "KeyType": "HASH"}],
        )
        with patch.dict(os.environ, {"COGNITO_EMISOR": emisor, "COGNITO_AUDIENCIA": audiencia,
                                    "COGNITO_CLIENTE": "cliente-validacion", "COGNITO_ALCANCE": audiencia + "/alias",
                                    "TABLA_VINCULOS": "vinculos", "TABLA_PERMISOS_NOTA": "permisos",
                                    "COGNITO_VINCULOS": json.dumps({sujeto: self.profesional})}), \
                patch("identidad_cognito.claves") as proveedor:
            proveedor.return_value.get_signing_key_from_jwt.return_value.key = self.privada.public_key()
            self.assertEqual(self.guardar(prueba=jwt_realista)["codigo"], "OK")
            self.assertEqual(self.resolver(prueba=jwt_realista)["codigo"], "OK")
            sesion = str(uuid4())
            permiso = self.resolver(prueba=jwt_realista, sesion=sesion, proposito="AUTORIZAR_NOTA")["permiso"]
            self.assertEqual(self.resolver(prueba=None, sesion=sesion, proposito="NOTA_AUTOMATICA", permiso=permiso)
                             ["alias"][self.ref["token"]], self.alias)
            self.assertEqual(self.resolver(prueba=None, sesion=str(uuid4()), proposito="NOTA_AUTOMATICA", permiso=permiso),
                             {"codigo": "ACCESO_DENEGADO"})
            patrones = self.resolver(prueba=jwt_realista, sesion=sesion, proposito="AUTORIZAR_PATRONES")["permiso"]
            self.assertEqual(self.resolver(prueba=None, sesion=sesion, proposito="PATRONES_AUTOMATICOS", permiso=patrones)
                             ["alias"][self.ref["token"]], self.alias)
            for proposito, otro_permiso in [("NOTA_AUTOMATICA", patrones), ("PATRONES_AUTOMATICOS", permiso)]:
                self.assertEqual(self.resolver(prueba=None, sesion=sesion, proposito=proposito, permiso=otro_permiso),
                                 {"codigo": "ACCESO_DENEGADO"})
            self.assertEqual(self.resolver(prueba=None, sesion=str(uuid4()), proposito="PATRONES_AUTOMATICOS", permiso=patrones),
                             {"codigo": "ACCESO_DENEGADO"})
            self.assertEqual(self.resolver(prueba=None, sesion=sesion, proposito="PATRONES_AUTOMATICOS", permiso=patrones,
                                          profesional=self.ajeno), {"codigo": "ACCESO_DENEGADO"})
            self.assertNotIn(permiso, json.dumps(self.ddb.scan(TableName="permisos")["Items"]))
            self.assertNotIn(patrones, json.dumps(self.ddb.scan(TableName="permisos")["Items"]))
            clave_nota = {"huella": {"S": hashlib.sha256(permiso.encode()).hexdigest()}}
            self.ddb.update_item(TableName="permisos", Key=clave_nota, UpdateExpression="REMOVE proposito")
            self.assertEqual(self.resolver(prueba=None, sesion=sesion, proposito="NOTA_AUTOMATICA", permiso=permiso)
                             ["alias"][self.ref["token"]], self.alias)
            self.assertEqual(self.resolver(prueba=None, sesion=sesion, proposito="PATRONES_AUTOMATICOS", permiso=permiso),
                             {"codigo": "ACCESO_DENEGADO"})
            self.ddb.put_item(TableName="vinculos", Item={**item, "activo": {"BOOL": False}})
            self.assertEqual(self.resolver(prueba=jwt_realista), {"codigo": "ACCESO_DENEGADO"})
            self.assertEqual(self.guardar(prueba=jwt_realista), {"codigo": "ACCESO_DENEGADO"})
            self.assertEqual(self.resolver(prueba=None, sesion=sesion, proposito="NOTA_AUTOMATICA", permiso=permiso),
                             {"codigo": "ACCESO_DENEGADO"})
            self.assertEqual(self.resolver(prueba=None, sesion=sesion, proposito="PATRONES_AUTOMATICOS", permiso=patrones),
                             {"codigo": "ACCESO_DENEGADO"})
