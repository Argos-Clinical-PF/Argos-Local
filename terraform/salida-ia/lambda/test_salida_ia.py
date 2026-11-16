import copy
import base64
import io
import json
import unittest
from unittest.mock import Mock

from botocore.exceptions import ClientError
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

from salida_ia import autorizar_contexto, invocar


class SalidaIATest(unittest.TestCase):
    def setUp(self):
        self.modelos = {"MODELO_CLINICA": "perfil-configurado", "MODELO_TEMAS": "perfil-temas"}
        self.evento = {"version": 2, "perfil": "clinica", "contexto": {
            "proposito": "NOTA", "profesional": "0a87cac4-6f66-4f51-a219-125f01acc3a8",
            "sesion": "ab87cac4-6f66-4f51-a219-125f01acc3a8",
            "alcancesEvidencia": ["TRANSCRIPCION_LOCAL"],
        }, "cuerpo": {
            "max_tokens": 2000, "system": [{"type": "text", "text": "Citar fragmentos"}],
            "messages": [{"role": "user", "content": [{"type": "text", "text": "No duerme desde el 12/04 [F1]."}]}],
        }}
        self.cliente = Mock()
        self.autorizador = Mock(return_value=204)
        self.cliente.invoke_model.return_value = {"body": io.BytesIO(b'{"content":[{"type":"text","text":"[F1]"}]}')}

    def probar(self, evento=None):
        return invocar(self.evento if evento is None else evento, self.cliente, self.modelos, self.autorizador)

    def test_modelo_seleccionado_por_el_servicio_y_contexto_intacto(self):
        self.assertEqual(self.probar()["codigo"], "OK")
        self.cliente.invoke_model.assert_called_once()
        parametros = self.cliente.invoke_model.call_args.kwargs
        self.assertEqual(parametros["modelId"], "perfil-configurado")
        cuerpo = json.loads(parametros["body"])
        self.assertEqual(cuerpo["anthropic_version"], "bedrock-2023-05-31")
        self.assertEqual(cuerpo["messages"], self.evento["cuerpo"]["messages"])
        self.assertNotIn("profesional", cuerpo)
        self.assertNotIn("sesion", cuerpo)
        self.autorizador.assert_called_once_with(self.evento["contexto"])

    def test_rechaza_desvio_de_modelo_y_limites(self):
        for evento in ({**self.evento, "perfil": "otro-modelo"},
                       {**self.evento, "version": True},
                       {**self.evento, "perfil": "temas"},
                       {**self.evento, "contexto": {"proposito": "GENERAL", "profesional": "arbitrario"}},
                       {**self.evento, "cuerpo": {**self.evento["cuerpo"], "model": "intruso"}},
                       {**self.evento, "cuerpo": {**self.evento["cuerpo"], "max_tokens": 10000}}):
            with self.subTest(evento=evento):
                self.assertEqual(self.probar(evento)["codigo"], "SOLICITUD_INVALIDA")
        self.cliente.invoke_model.assert_not_called()
        self.autorizador.assert_not_called()

    def test_consentimiento_negado_o_no_disponible_impide_la_inferencia(self):
        for estado, codigo in ((403, "CONSENTIMIENTO_DENEGADO"), (500, "AUTORIZADOR_NO_DISPONIBLE"),
                               (200, "AUTORIZADOR_NO_DISPONIBLE"), (307, "AUTORIZADOR_NO_DISPONIBLE")):
            self.autorizador.return_value = estado
            self.assertEqual(self.probar()["codigo"], codigo)
        self.cliente.invoke_model.assert_not_called()

    def test_firma_los_metadatos_sin_enviar_texto_clinico_al_autorizador(self):
        clave = Ed25519PrivateKey.generate()
        contexto = self.evento["contexto"]

        def abrir(pedido, timeout):
            self.assertEqual(timeout, 3)
            self.assertEqual(json.loads(pedido.data), contexto)
            fecha = pedido.headers["X-argos-fecha"]
            firma = base64.urlsafe_b64decode(pedido.headers["X-argos-firma"] + "==")
            clave.public_key().verify(firma, f"argos-salida-ia-v2\n{fecha}\n".encode() + pedido.data)
            respuesta = unittest.mock.MagicMock()
            respuesta.__enter__.return_value.status = 204
            return respuesta

        self.assertEqual(autorizar_contexto(contexto, cargar_clave=lambda: clave, abrir=abrir), 204)

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
