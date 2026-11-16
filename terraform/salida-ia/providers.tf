terraform {
  required_version = ">= 1.11"

  backend "s3" {
    bucket       = "argos-terraform-estado-616322963974"
    key          = "argos/tokenizacion/salida-ia.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
    profile      = "argos-nuevos"
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.100"
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

variable "exigir_salida_aislada" {
  type        = bool
  default     = false
  description = "Deniega la inferencia directa de la aplicacion tras validar la salida dedicada"
}
