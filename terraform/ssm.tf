/*
 * 시크릿을 Secrets Manager 가 아니라 Parameter Store 에 둔다 (INF-11).
 * Secrets Manager 는 시크릿당 월 0.40 USD 이고 표준 파라미터는 무료다.
 *
 * SecureString 의 실제 값은 Terraform 이 넣지 않는다.
 * 넣으면 상태 파일에 평문으로 남는다. 자리만 만들고 값은 CLI 로 채운다.
 */

locals {
  ssm_prefix = "/${var.project}"

  # 자리만 만들고 값은 밖에서 채우는 시크릿들
  secure_params = {
    "jwt-signing-key"        = "JWT signing key. rotated by kid"
    "db-password"            = "RDS master password"
    "db-exporter-password"   = "mysqld_exporter account. separate from master"
    "github-token"           = "used by monitoring to clone observability config"
    "ghcr-token"             = "used by instances to pull images from GHCR. needs read:packages"
    "slack-webhook-critical" = "Alertmanager critical channel"
    "slack-webhook-warning"  = "Alertmanager warning channel"
    "slack-webhook-watchdog" = "Alertmanager watchdog channel"
  }
}

/*
 * ASG 가 인스턴스를 교체할 때 어느 버전을 띄울지 여기서 읽는다 (INF-25).
 * 값은 배포 스크립트가 갱신하므로 Terraform 이 건드리면 안 된다.
 * ignore_changes 가 없으면 다음 apply 가 bootstrap 으로 되돌려 전 인스턴스가 구버전으로 기동한다.
 */
resource "aws_ssm_parameter" "current_sha" {
  name        = "${local.ssm_prefix}/current-sha"
  description = "currently deployed commit SHA"
  type        = "String"
  value       = "bootstrap"

  lifecycle {
    ignore_changes = [value]
  }
}

/*
 * RDS 복원은 항상 새 인스턴스를 만들어 엔드포인트가 바뀐다 (INF-26).
 * 초기값은 Terraform 이 넣지만 복원 후 갱신은 CLI 가 한다.
 */
resource "aws_ssm_parameter" "db_endpoint" {
  name        = "${local.ssm_prefix}/db-endpoint"
  description = "DB endpoint for app and batch"
  type        = "String"
  value       = "unset"

  lifecycle {
    ignore_changes = [value]
  }
}

# redis_exporter 가 붙을 주소. RDS 와 같은 이유로 복원 시 바뀔 수 있다.
resource "aws_ssm_parameter" "cache_endpoint" {
  name        = "${local.ssm_prefix}/cache-endpoint"
  description = "cache endpoint for monitoring"
  type        = "String"
  value       = "unset"

  lifecycle {
    ignore_changes = [value]
  }
}

/*
 * Alloy 가 로그를 밀어 넣을 주소다.
 * 모니터링은 ASG 밖 고정 인스턴스라 Terraform 이 IP 를 안다.
 * 앱 시작 템플릿에 박지 않고 SSM 을 거치는 이유는, 박으면 IP 가 바뀔 때 템플릿을 다시 렌더링해야 하기 때문이다.
 */
resource "aws_ssm_parameter" "loki_endpoint" {
  name        = "${local.ssm_prefix}/loki-endpoint"
  description = "Loki address for Alloy log push"
  type        = "String"
  value       = aws_instance.monitoring.private_ip
}

resource "aws_ssm_parameter" "secure" {
  for_each = local.secure_params

  name        = "${local.ssm_prefix}/${each.key}"
  description = each.value
  type        = "SecureString"
  value       = "unset"

  # 실제 값은 aws ssm put-parameter 로 넣는다. 상태 파일에 남기지 않는다.
  lifecycle {
    ignore_changes = [value]
  }
}
