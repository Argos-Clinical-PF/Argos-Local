#!/usr/bin/env bash
# Instala el driver NVIDIA y el runtime de contenedores en la instancia de ARGOS (Amazon Linux 2023)
# después de cambiarla a un tipo con GPU. Se corre una sola vez, por SSM, con la instancia ya en el
# tipo GPU; el disco (y la base) se conservan porque Terraform ignora cambios de AMI.
#
#   aws ssm send-command ... --parameters commands=["bash /opt/argos/scripts/habilitar-gpu.sh"]
#
# Idempotente: si nvidia-smi ya responde y Docker ya tiene el runtime, no hace nada.
set -euo pipefail

if nvidia-smi >/dev/null 2>&1 && docker info 2>/dev/null | grep -qi 'nvidia'; then
  echo "GPU y runtime ya configurados"; nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
  exit 0
fi

lspci 2>/dev/null | grep -qi nvidia || { echo "No se detecta una GPU NVIDIA: ¿la instancia ya es de tipo g6?"; exit 1; }

dnf install -y "kernel-devel-$(uname -r)" "kernel-headers-$(uname -r)" "kernel-modules-extra-$(uname -r)" dkms
dnf config-manager --add-repo https://developer.download.nvidia.com/compute/cuda/repos/amzn2023/x86_64/cuda-amzn2023.repo
dnf clean expire-cache
# Módulos abiertos: los recomendados por NVIDIA para Turing en adelante (la L4 de g6 es Ada).
dnf install -y nvidia-open || dnf install -y cuda-drivers

curl -fsSL https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo \
  -o /etc/yum.repos.d/nvidia-container-toolkit.repo
dnf install -y nvidia-container-toolkit
nvidia-ctk runtime configure --runtime=docker
systemctl restart docker

nvidia-smi --query-gpu=name,driver_version,memory.total --format=csv
docker run --rm --gpus all public.ecr.aws/amazonlinux/amazonlinux:2023 nvidia-smi -L
echo "GPU lista. Siguiente paso: parámetro demo-gpu=true y redesplegar el bundle."
