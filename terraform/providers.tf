terraform {
  required_version = ">= 1.5"
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

variable "public_base_url" {
  description = "Origen HTTPS permitido. Vacio usa sslip.io sobre la Elastic IP."
  default     = ""
}

variable "monthly_budget_usd" {
  description = "Presupuesto mensual de seguridad para el MVP."
  default     = 25
}

variable "budget_email" {
  description = "Correo que recibe alertas de AWS Budgets."
  default     = "95001@sistemas.frc.utn.edu.ar"
}
