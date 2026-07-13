import importlib.util
import os
import sys
import types
import unittest
from datetime import datetime, timedelta, timezone
from pathlib import Path


class _Paginator:
    def __init__(self, pages):
        self.pages = pages

    def paginate(self, **_kwargs):
        return self.pages


class _S3Falso:
    def __init__(self, objects=None, uploads=None, tags=None):
        self.objects = objects or []
        self.uploads = uploads or []
        self.tags = tags or {}
        self.deleted = []
        self.aborted = []

    def get_paginator(self, name):
        if name == "list_objects_v2":
            return _Paginator([{"Contents": self.objects}])
        return _Paginator([{"Uploads": self.uploads}])

    def get_object_tagging(self, Bucket, Key):
        return {"TagSet": self.tags.get(Key, [])}

    def delete_object(self, Bucket, Key):
        self.deleted.append(Key)

    def abort_multipart_upload(self, Bucket, Key, UploadId):
        self.aborted.append((Key, UploadId))


def _load_module():
    os.environ["BUCKET"] = "bucket-prueba"
    boto3 = types.ModuleType("boto3")
    boto3.client = lambda _name: _S3Falso()
    botocore = types.ModuleType("botocore")
    botocore_exceptions = types.ModuleType("botocore.exceptions")
    botocore_exceptions.ClientError = type("ClientError", (Exception,), {})
    sys.modules["boto3"] = boto3
    sys.modules["botocore"] = botocore
    sys.modules["botocore.exceptions"] = botocore_exceptions
    path = Path(__file__).with_name("eliminar_grabaciones.py")
    spec = importlib.util.spec_from_file_location("eliminar_grabaciones", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class EliminarGrabacionesTest(unittest.TestCase):
    def test_elimina_solo_objetos_con_vencimiento_cumplido(self):
        module = _load_module()
        now = datetime.now(timezone.utc)
        old = now - timedelta(days=2)
        storage = _S3Falso(
            objects=[
                {"Key": "vencido", "LastModified": old},
                {"Key": "vigente", "LastModified": old},
            ],
            tags={
                "vencido": [{"Key": module.DELETE_AT_TAG, "Value": str(int((now - timedelta(minutes=1)).timestamp()))}],
                "vigente": [{"Key": module.DELETE_AT_TAG, "Value": str(int((now + timedelta(days=7)).timestamp()))}],
            },
        )
        module.s3 = storage

        result = module.handler({}, None)

        self.assertEqual(["vencido"], storage.deleted)
        self.assertEqual(1, result["eliminados"])

    def test_objeto_sin_etiqueta_usa_maximo_tecnico(self):
        module = _load_module()
        now = datetime.now(timezone.utc)
        storage = _S3Falso(objects=[
            {"Key": "antiguo", "LastModified": now - timedelta(days=31)},
            {"Key": "reciente", "LastModified": now - timedelta(days=1)},
        ])
        module.s3 = storage

        module.handler({}, None)

        self.assertEqual(["antiguo"], storage.deleted)

    def test_aborta_multipart_incompleto_despues_de_24_horas(self):
        module = _load_module()
        now = datetime.now(timezone.utc)
        storage = _S3Falso(uploads=[
            {"Key": "abortar", "UploadId": "1", "Initiated": now - timedelta(hours=25)},
            {"Key": "mantener", "UploadId": "2", "Initiated": now - timedelta(hours=2)},
        ])
        module.s3 = storage

        result = module.handler({}, None)

        self.assertEqual([("abortar", "1")], storage.aborted)
        self.assertEqual(1, result["multipart_abortados"])


if __name__ == "__main__":
    unittest.main()
