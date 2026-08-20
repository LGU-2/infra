/*
 * Terraform 상태를 담을 S3 버킷을 만든다.
 * 상태 버킷 자체는 상태에 담을 수 없어 닭과 달걀이라 이 구성만 로컬 상태로 돌린다.
 * 한 번 만들면 다시 실행할 일이 없다.
 */

terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = var.region

  # terraform/ 과 같은 계정을 가리켜야 한다. 상태 버킷이 거기 있기 때문이다.
  profile             = var.aws_profile != "" ? var.aws_profile : null
  allowed_account_ids = var.allowed_account_ids

  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
      Component = "bootstrap"
    }
  }
}

variable "project" {
  description = "모든 리소스 이름의 접두사"
  type        = string
  default     = "freshmarket"
}

variable "region" {
  description = "AWS 리전"
  type        = string
  default     = "ap-northeast-2"
}

variable "aws_profile" {
  description = "AWS CLI 프로파일 이름. 비우면 기본 자격증명을 쓴다"
  type        = string
  default     = ""
}

variable "allowed_account_ids" {
  description = "이 구성을 적용해도 되는 AWS 계정 ID"
  type        = list(string)
  default     = []
}

resource "aws_s3_bucket" "tfstate" {
  bucket = "tfstate-${var.project}"

  /*
   * 상태 파일을 잃으면 이미 만든 리소스를 Terraform 이 모르게 된다.
   * 전부 import 로 되찾거나 손으로 지워야 하므로 삭제를 막는다.
   */
  lifecycle {
    prevent_destroy = true
  }
}

# 잘못된 apply 로 상태가 깨졌을 때 되돌릴 유일한 수단이다.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  versioning_configuration {
    status = "Enabled"
  }
}

# 상태 파일에는 DB 비밀번호 같은 값이 평문으로 들어간다.
resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "bucket" {
  description = "terraform/backend.hcl 의 bucket 값"
  value       = aws_s3_bucket.tfstate.id
}
