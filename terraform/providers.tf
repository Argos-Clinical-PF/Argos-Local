terraform {
  required_version = ">= 1.5"
  backend "local" {}
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.7"
    }
  }
}

provider "aws" {
  region  = var.region
  profile = var.profile
  default_tags {
    tags = {
      Project   = "ARGOS"
      ManagedBy = "Terraform"
    }
  }
}

variable "region" {
  default = "us-east-1"
}

variable "profile" {
  description = "Perfil AWS CLI (la cuenta FACU). NUNCA default."
  default     = "argos-facu"
}

variable "instance_type" {
  default = "c7i.2xlarge"
}

variable "demo_gpu" {
  description = "Activa perfil demo con AMI GPU y compose overlay CUDA."
  default     = false
}

variable "gpu_instance_type" {
  description = "Instancia GPU para demos. Requiere cuota EC2 G/VT aprobada."
  default     = "g5.xlarge"
}

variable "public_base_url" {
  description = "Origen HTTPS adicional permitido. Vacio usa los endpoints administrados por Terraform."
  default     = ""
}

variable "cloudfront_fallback_enabled" {
  description = "Publica un endpoint TLS/DNS estable de CloudFront mientras Route 53 Domains esta bloqueado."
  type        = bool
  default     = false
}

variable "monthly_budget_usd" {
  description = "Presupuesto mensual de seguridad para el MVP."
  default     = 25
}

variable "budget_email" {
  description = "Correo que recibe alertas de AWS Budgets."
  default     = "95001@sistemas.frc.utn.edu.ar"
}
