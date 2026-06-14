#!/bin/bash
set -e
dnf update -y
dnf install -y docker amazon-ssm-agent
systemctl enable --now docker
systemctl enable --now amazon-ssm-agent
usermod -aG docker ec2-user

# Proteccion ante picos puntuales de memoria del modelo de transcripcion.
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi

# Plugin de Docker Compose (la EC2 NO compila: solo baja imágenes de ECR y corre)
mkdir -p /usr/local/lib/docker/cli-plugins
curl -SL https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-x86_64 \
  -o /usr/local/lib/docker/cli-plugins/docker-compose
chmod +x /usr/local/lib/docker/cli-plugins/docker-compose

mkdir -p /home/ec2-user/argos
chown ec2-user:ec2-user /home/ec2-user/argos
