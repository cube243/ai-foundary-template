terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.60"
    }
    tls = {
      source  = "hashicorp/tls"
      version = ">= 4.0"
    }
  }

  # Intentionally local state: this stack creates the S3 bucket / DynamoDB
  # table that every other stack in this repository uses as its remote
  # backend, so it cannot depend on that backend itself. Run it locally via
  # scripts/bootstrap.bat and keep the resulting terraform.tfstate safe
  # (it is git-ignored; treat it like a secret).
}

provider "aws" {
  region = var.region
}
