terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.18"
    }
    awscc = {
      source  = "hashicorp/awscc"
      version = ">= 1.30"
    }
  }

  # Partial backend, same pattern as shared-infra/cognito — see
  # backend.hcl.example for the values `terraform init -backend-config`
  # needs.
  backend "s3" {
    key     = "agents/rename.tfstate"
    encrypt = true
  }
}

provider "aws" {
  region = var.region
}

provider "awscc" {
  region = var.region
}
