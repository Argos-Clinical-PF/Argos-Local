"""Enciende el host GPU cada vez que la app pasa a running, la arranque quien la arranque (Operate
MVP, un deploy, la consola). Apagarlo sigue siendo del vigía del host, que lo baja cuando la app no
corre."""
import os

import boto3

ASG = os.environ["ASG_INFERENCIA"]
INSTANCIA_APP = os.environ["INSTANCIA_APP"]

autoscaling = boto3.client("autoscaling")


def handler(event, _context):
    detalle = event.get("detail", {})
    if detalle.get("instance-id") != INSTANCIA_APP or detalle.get("state") != "running":
        return {"encendido": False}
    autoscaling.set_desired_capacity(AutoScalingGroupName=ASG, DesiredCapacity=1, HonorCooldown=False)
    return {"encendido": True}
