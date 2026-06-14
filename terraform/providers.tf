terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
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
  default = "t3.medium"
}
