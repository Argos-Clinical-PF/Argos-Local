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
  description = "Perfil AWS CLI de la cuenta donde se aplica (616322963974 = argos-nuevos)."
  default     = "argos-nuevos"
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

variable "waf_habilitado" {
  description = "Crea el WebACL propio y lo asocia a CloudFront. Cuesta del orden de USD 9/mes."
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

# Orígenes extra para las subidas directas del navegador al bucket de grabaciones. El bucket sólo
# admite `https://<domain_name>`; mientras la app se sirva desde un host provisorio (hoy
# https://nuevo.argosclinical.online, hasta el cambio de NS) hay que listarlo acá o ninguna parte
# llega a S3 y las grabaciones quedan en INICIADA. Vaciar cuando el dominio definitivo esté activo.
variable "origenes_cors_adicionales" {
  description = "Orígenes adicionales (https://host) permitidos por CORS en el bucket de grabaciones."
  type        = list(string)
  default     = []
}
