terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "5.78.0"
    }
  }
}

provider "aws" {
  region = "ap-northeast-1"
}

data "aws_caller_identity" "this" {}
data "aws_region" "this" {}


locals {
  prefix     = "ecslattice"
  region     = data.aws_region.this.name
  account_id = data.aws_caller_identity.this.account_id
}
