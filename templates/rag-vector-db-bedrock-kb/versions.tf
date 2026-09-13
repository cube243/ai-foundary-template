terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }

  # No backend block on purpose: this folder is copied out standalone by
  # each user (see the "complete independence" rule in this template's
  # README) and must not assume any particular backend layout. Configure
  # your own backend after copying this template out.
}

provider "aws" {
  region = var.region
}
