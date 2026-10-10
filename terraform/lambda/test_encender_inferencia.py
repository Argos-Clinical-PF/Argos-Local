import importlib.util
import os
import sys
import types
import unittest
from pathlib import Path


class _AutoscalingFalso:
    def __init__(self):
        self.llamadas = []

    def set_desired_capacity(self, **kwargs):
        self.llamadas.append(kwargs)


def _cargar(autoscaling):
    os.environ["ASG_INFERENCIA"] = "argos-inferencia"
    os.environ["INSTANCIA_APP"] = "i-app"
    sys.modules["boto3"] = types.SimpleNamespace(client=lambda _nombre: autoscaling)
    ruta = Path(__file__).with_name("encender_inferencia.py")
    spec = importlib.util.spec_from_file_location("encender_inferencia", ruta)
    modulo = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(modulo)
    return modulo


def _evento(instancia, estado):
    return {"detail": {"instance-id": instancia, "state": estado}}


class EncenderInferenciaTest(unittest.TestCase):
    def test_la_app_en_running_enciende_el_host_gpu(self):
        autoscaling = _AutoscalingFalso()
        resultado = _cargar(autoscaling).handler(_evento("i-app", "running"), None)
        self.assertEqual(resultado, {"encendido": True})
        self.assertEqual(autoscaling.llamadas, [
            {"AutoScalingGroupName": "argos-inferencia", "DesiredCapacity": 1, "HonorCooldown": False}])

    def test_otra_instancia_u_otro_estado_no_hace_nada(self):
        autoscaling = _AutoscalingFalso()
        modulo = _cargar(autoscaling)
        self.assertEqual(modulo.handler(_evento("i-otra", "running"), None), {"encendido": False})
        self.assertEqual(modulo.handler(_evento("i-app", "stopping"), None), {"encendido": False})
        self.assertEqual(autoscaling.llamadas, [])


if __name__ == "__main__":
    unittest.main()
