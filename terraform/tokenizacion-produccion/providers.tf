terraform {
  required_version = ">= 1.11"

  backend "s3" {
    bucket       = "argos-terraform-estado-616322963974"
    key          = "argos/tokenizacion/produccion.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
    profile      = "argos-nuevos"
  }

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
      Environment = "produccion"
      ManagedBy   = "Terraform"
    }
  }
}

variable "administrador_boveda" {
  type        = string
  description = "Principal IAM de administracion de la boveda que ejecuta Terraform"

  validation {
    condition = can(regex("^arn:aws:iam::616322963974:(role|user)/[A-Za-z0-9+=,.@_/-]+$", var.administrador_boveda)) && !contains([
      "arn:aws:iam::616322963974:role/argos-ec2-role",
      "arn:aws:iam::616322963974:role/argos-github-actions"
    ], var.administrador_boveda)
    error_message = "Usar un principal de administracion de ARGOS separado de la app y CI."
  }
}
