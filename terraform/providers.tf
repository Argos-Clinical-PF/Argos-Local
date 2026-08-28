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

variable "domain_name" {
  description = "Dominio publico canonico de ARGOS Clinical."
  type        = string
  default     = "argosclinical.online"

  validation {
    condition     = can(regex("^[a-z0-9.-]+$", var.domain_name)) && !startswith(var.domain_name, ".") && !endswith(var.domain_name, ".")
    error_message = "domain_name debe ser un nombre DNS en minusculas y sin punto final."
  }
}

variable "dev_cors_origins" {
  description = "Origenes adicionales permitidos para subir partes multipart al bucket de grabaciones (aws_s3_bucket_cors_configuration.grabaciones), ademas del dominio publico. Pensado para el frontend de desarrollo local (http://localhost:5173): sin esto, cualquier subida de audio de procesamiento/retencion hecha en local contra el bucket real falla por CORS -el navegador nunca deja completar el PUT presignado- aunque la URL y la firma sean validas. Vacio por defecto para no tocar produccion; cada quien lo agrega en su propio terraform.tfvars (gitignored), nunca en este archivo."
  type        = list(string)
  default     = []
}

variable "monthly_budget_usd" {
  description = "Presupuesto mensual de seguridad para el MVP."
  default     = 25
}

variable "budget_email" {
  description = "Correo que recibe alertas de AWS Budgets."
  default     = "95001@sistemas.frc.utn.edu.ar"
}
