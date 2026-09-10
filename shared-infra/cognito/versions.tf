terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60"
    }
  }

  # Partial backend: bucket/table/region come from shared-infra/bootstrap's
  # outputs and are supplied at `terraform init` time via -backend-config
  # (see backend.hcl.example), never hardcoded here.
  backend "s3" {
    key     = "shared-infra/cognito.tfstate"
    encrypt = true
  }
}

provider "aws" {
  region = var.region
}
