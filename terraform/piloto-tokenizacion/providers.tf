terraform {
  required_version = ">= 1.11"
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
  region              = "us-east-1"
  profile             = "argos-nuevos"
  allowed_account_ids = ["616322963974"]

  default_tags {
    tags = {
      Project     = "ARGOS"
      Environment = "piloto-tokenizacion"
      ManagedBy   = "Terraform"
    }
  }
}

variable "clave_publica" {
  type        = string
  description = "Clave publica RSA del emisor sintetico en formato PEM"
}

variable "profesionales" {
  type        = set(string)
  description = "Identificadores de los dos profesionales ficticios"

  validation {
    condition = length(var.profesionales) == 2 && alltrue([
      for id in var.profesionales : can(regex("^[0-9a-f]{8}(-[0-9a-f]{4}){3}-[0-9a-f]{12}$", id))
    ])
    error_message = "Usar dos UUID canonicos distintos."
  }
}

variable "principal_de_pruebas" {
  type        = string
  description = "ARN IAM del operador autorizado a asumir el rol de invocacion del piloto"

  validation {
    condition     = can(regex("^arn:aws:iam::616322963974:(role|user)/[^*]+$", var.principal_de_pruebas))
    error_message = "Usar un principal IAM concreto de la cuenta ARGOS."
  }
}
