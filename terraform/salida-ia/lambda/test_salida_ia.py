import copy
import io
import json
import unittest
from unittest.mock import Mock

from botocore.exceptions import ClientError

from salida_ia import invocar


class SalidaIATest(unittest.TestCase):
    def setUp(self):
        self.modelos = {"MODELO_CLINICA": "perfil-configurado", "MODELO_TEMAS": "perfil-temas"}
        self.evento = {"version": 1, "perfil": "clinica", "cuerpo": {
            "max_tokens": 2000, "system": [{"type": "text", "text": "Citar fragmentos"}],
            "messages": [{"role": "user", "content": [{"type": "text", "text": "No duerme desde el 12/04 [F1]."}]}],
        }}
        self.cliente = Mock()
        self.cliente.invoke_model.return_value = {"body": io.BytesIO(b'{"content":[{"type":"text","text":"[F1]"}]}')}

    def probar(self, evento=None):
        return invocar(self.evento if evento is None else evento, self.cliente, self.modelos)

    def test_modelo_seleccionado_por_el_servicio_y_contexto_intacto(self):
        self.assertEqual(self.probar()["codigo"], "OK")
        self.cliente.invoke_model.assert_called_once()
        parametros = self.cliente.invoke_model.call_args.kwargs
        self.assertEqual(parametros["modelId"], "perfil-configurado")
        cuerpo = json.loads(parametros["body"])
        self.assertEqual(cuerpo["anthropic_version"], "bedrock-2023-05-31")
        self.assertEqual(cuerpo["messages"], self.evento["cuerpo"]["messages"])

    def test_rechaza_desvio_de_modelo_y_limites(self):
        for evento in ({**self.evento, "perfil": "otro-modelo"},
                       {**self.evento, "version": True},
                       {**self.evento, "cuerpo": {**self.evento["cuerpo"], "model": "intruso"}},
                       {**self.evento, "cuerpo": {**self.evento["cuerpo"], "max_tokens": 10000}}):
            with self.subTest(evento=evento):
                self.assertEqual(self.probar(evento)["codigo"], "SOLICITUD_INVALIDA")
        self.cliente.invoke_model.assert_not_called()

    def test_rechaza_identificador_anidado_sin_llamar_al_modelo(self):
        for dato in ("ejemplo@example.test", "http://example.test/privado",
                     "DNI 12.345.678", "+54 351 555 1212", "0a87cac4-6f66-4f51-a219-125f01acc3a8"):
            evento = copy.deepcopy(self.evento)
            evento["cuerpo"]["messages"][0]["content"].append({"type": "text", "text": dato})
            with self.subTest(dato=dato):
                self.assertEqual(self.probar(evento), {"codigo": "IDENTIFICADOR_DETECTADO", "estado": 422})
        self.cliente.invoke_model.assert_not_called()

    def test_admite_herramientas_locales_y_rechaza_bloques_multimedia(self):
        self.evento["cuerpo"]["messages"].append({"role": "assistant", "content": [
            {"type": "tool_use", "name": "buscar", "id": "toolu_1", "input": {"consulta": "descanso"}},
        ]})
        self.evento["cuerpo"]["messages"].append({"role": "user", "content": [
            {"type": "tool_result", "tool_use_id": "toolu_1", "content": "evidencia [F1]"},
        ]})
        self.assertEqual(self.probar()["codigo"], "OK")
        evento = copy.deepcopy(self.evento)
        evento["cuerpo"]["messages"][0]["content"].append({
            "type": "image", "source": {"type": "base64", "data": "AABB"},
        })
        self.assertEqual(self.probar(evento)["codigo"], "SOLICITUD_INVALIDA")
        self.cliente.invoke_model.assert_called_once()

    def test_error_del_proveedor_no_repite_ni_devuelve_el_mensaje(self):
        self.cliente.invoke_model.side_effect = ClientError(
            {"Error": {"Code": "ThrottlingException", "Message": "texto sintético"}},
            "InvokeModel",
        )
        self.assertEqual(self.probar(), {"codigo": "CUOTA", "estado": 429})
        self.cliente.invoke_model.assert_called_once()
