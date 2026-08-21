/*
 * 도메인이 없으면 만들지 않는다.
 * var.domain_name 을 채우면 호스팅 영역, 인증서, HTTPS 리스너가 함께 생긴다.
 *
 * stateless JWT 가 헤더로 오가므로 평문 구간을 둘 수 없다 (INF-17, 되돌릴 수 없음).
 * 즉 도메인이 없는 상태는 임시다.
 */

locals {
  has_domain = var.domain_name != ""

  # api.example.com 에서 example.com 을 뽑는다
  zone_name = local.has_domain ? join(".", slice(split(".", var.domain_name), 1, length(split(".", var.domain_name)))) : ""
}

resource "aws_route53_zone" "main" {
  count = local.has_domain ? 1 : 0

  name    = local.zone_name
  comment = "${var.project} service domain"

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_acm_certificate" "main" {
  count = local.has_domain ? 1 : 0

  domain_name       = var.domain_name
  validation_method = "DNS"

  # 인증서를 갈아끼울 때 리스너가 옛 인증서를 참조한 채로 남지 않게 한다.
  lifecycle {
    create_before_destroy = true
  }
}

/*
 * 검증 레코드를 Terraform 관리 대상에 넣는다 (INF-12-18).
 * ACM 자동 갱신은 이 레코드가 살아 있을 때만 된다.
 * 레코드가 사라지면 갱신이 조용히 실패하고 만료 시점에야 드러난다.
 */
resource "aws_route53_record" "cert_validation" {
  for_each = local.has_domain ? {
    for o in aws_acm_certificate.main[0].domain_validation_options : o.domain_name => o
  } : {}

  zone_id         = aws_route53_zone.main[0].zone_id
  name            = each.value.resource_record_name
  type            = each.value.resource_record_type
  records         = [each.value.resource_record_value]
  ttl             = 60
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "main" {
  count = local.has_domain ? 1 : 0

  certificate_arn         = aws_acm_certificate.main[0].arn
  validation_record_fqdns = [for r in aws_route53_record.cert_validation : r.fqdn]
}

resource "aws_route53_record" "alb" {
  count = local.has_domain ? 1 : 0

  zone_id = aws_route53_zone.main[0].zone_id
  name    = var.domain_name
  type    = "A"

  alias {
    name                   = aws_lb.main.dns_name
    zone_id                = aws_lb.main.zone_id
    evaluate_target_health = true
  }
}

/*
 * VPC 밖에서 보는 눈이다 (INF-19).
 * Prometheus 는 VPC 안이라 ALB 가 죽어도 앱 지표는 정상으로 보인다. 그 사각지대를 메운다.
 */
resource "aws_route53_health_check" "endpoint" {
  count = local.has_domain ? 1 : 0

  fqdn              = var.domain_name
  type              = "HTTPS"
  port              = 443
  resource_path     = "/actuator/health/liveness"
  request_interval  = 30
  failure_threshold = 2

  tags = {
    Name = "${var.project}-endpoint"
  }
}
