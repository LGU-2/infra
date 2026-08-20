/*
 * 확정값은 기술 스택 확정 문서 3.7절에 있다.
 * 코어 버전보다 프로바이더 버전 고정이 실질적으로 더 중요하다. 리소스 스키마가 거기서 바뀐다.
 */

terraform {
  required_version = "~> 1.15"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }

  /*
   * bucket, key, region 은 backend.hcl 로 넘긴다.
   * backend 블록 안에서는 변수 보간이 안 되기 때문이다.
   * 잠금은 DynamoDB 테이블이 아니라 S3 네이티브 잠금을 쓴다.
   */
  backend "s3" {
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.region

  /*
   * 모든 리소스에 붙는다.
   * 비용 배분과 일괄 조회의 근거가 되고, 콘솔에서 손으로 만든 것과 구분된다.
   */
  default_tags {
    tags = {
      Project   = var.project
      ManagedBy = "terraform"
    }
  }
}
