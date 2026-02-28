terraform {
  required_version = ">= 1.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
  default_tags {
    tags = {
      Project     = "nist-fileshare"
      ManagedBy   = "ralph-terraform"
      Environment = "ephemeral"
    }
  }
}

# ── Discover parent project infrastructure ──────────────────────────────────

data "aws_vpc" "nist" {
  id = "vpc-0029e7ab9f2917e2c"
}

data "aws_subnet" "private" {
  id = "subnet-0cff2938b18b3977a"
}

data "aws_kms_key" "nist" {
  key_id = "alias/nist-iac-builder"
}
