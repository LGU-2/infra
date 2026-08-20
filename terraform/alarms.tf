/*
 * CloudWatch 에 두는 판단 기준은 하나다. "모니터링 인스턴스가 죽어도 알아야 하는가".
 * 나머지는 Prometheus 가 본다. 무료 한도가 10개라 6개로 제한한다 (INF-31).
 *
 * 이상 탐지, 복합 알람, 고해상도 알람, 커스텀 지표, CloudWatch 대시보드는 쓰지 않는다.
 * 각각 별도 과금이라 예산을 조용히 갉아먹는다.
 */

resource "aws_sns_topic" "critical" {
  name         = "${var.project}-critical"
  display_name = "critical"
}

/*
 * AWS Chatbot 이 이 주제를 구독해 Slack 으로 옮긴다.
 * Chatbot 설정 자체는 콘솔 작업이라 여기서 하지 않는다. 주제만 만들어 둔다.
 * 이메일 구독은 Chatbot 이 죽었을 때의 대체 경로다.
 */
resource "aws_sns_topic_subscription" "email" {
  count = var.alert_email != "" ? 1 : 0

  topic_arn = aws_sns_topic.critical.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

# 모니터링 인스턴스가 죽으면 Prometheus 알람이 전부 침묵한다. 이것만은 밖에서 봐야 한다.
resource "aws_cloudwatch_metric_alarm" "monitoring_status" {
  alarm_name          = "${var.project}-monitoring-status"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_description   = "모니터링 인스턴스 상태 검사 실패. 재기동하라"

  dimensions = {
    InstanceId = aws_instance.monitoring.id
  }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]
}

# 정상 대상이 0이면 ALB 가 fail-open 으로 아무 데나 보낸다. 서비스가 사실상 끊긴 상태다.
resource "aws_cloudwatch_metric_alarm" "healthy_host_count" {
  alarm_name          = "${var.project}-healthy-host-count"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "HealthyHostCount"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  alarm_description   = "정상 대상이 없다. 앱 상태를 확인하라"
  treat_missing_data  = "breaching"

  dimensions = {
    LoadBalancer = aws_lb.main.arn_suffix
    TargetGroup  = aws_lb_target_group.app.arn_suffix
  }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]
}

/*
 * 인증서 갱신은 조용히 실패한다.
 * ACM DNS 검증은 자동 갱신되지만 검증 레코드가 사라지면 만료 시점에야 드러난다.
 */
resource "aws_cloudwatch_metric_alarm" "cert_expiry" {
  count = local.has_domain ? 1 : 0

  alarm_name          = "${var.project}-cert-expiry"
  namespace           = "AWS/CertificateManager"
  metric_name         = "DaysToExpiry"
  statistic           = "Minimum"
  period              = 86400
  evaluation_periods  = 1
  threshold           = 30
  comparison_operator = "LessThanThreshold"
  alarm_description   = "인증서 잔여일이 30일 미만이다. 검증 레코드를 확인하라"

  dimensions = {
    CertificateArn = aws_acm_certificate.main[0].arn
  }

  alarm_actions = [aws_sns_topic.critical.arn]
  ok_actions    = [aws_sns_topic.critical.arn]
}

/*
 * VPC 밖에서 보는 눈이다 (INF-19).
 * Prometheus 는 VPC 안이라 ALB 가 죽어도 앱 지표는 정상으로 보인다.
 * Route 53 지표는 us-east-1 에만 올라오므로 알람도 거기에 만든다.
 */
resource "aws_sns_topic" "critical_us_east_1" {
  count = local.has_domain ? 1 : 0

  provider     = aws.us_east_1
  name         = "${var.project}-critical"
  display_name = "critical"
}

resource "aws_cloudwatch_metric_alarm" "endpoint_health" {
  count = local.has_domain ? 1 : 0

  provider            = aws.us_east_1
  alarm_name          = "${var.project}-endpoint-health"
  namespace           = "AWS/Route53"
  metric_name         = "HealthCheckStatus"
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  alarm_description   = "외부에서 서비스에 닿지 못한다"

  dimensions = {
    HealthCheckId = aws_route53_health_check.endpoint[0].id
  }

  alarm_actions = [aws_sns_topic.critical_us_east_1[0].arn]
  ok_actions    = [aws_sns_topic.critical_us_east_1[0].arn]
}

/*
 * 지표 알람이 아니라 이벤트 구독이다.
 * 페일오버는 값이 아니라 사건이라 CloudWatch 지표로 표현되지 않는다.
 */
resource "aws_db_event_subscription" "failover" {
  name             = "${var.project}-failover"
  sns_topic        = aws_sns_topic.critical.arn
  source_type      = "db-instance"
  source_ids       = [aws_db_instance.main.identifier]
  event_categories = ["failover"]
}

/*
 * 백업 미생성 알람은 임계값이 정해지지 않아 만들지 않는다.
 * LatestRestorableTime 이 몇 분 이상 밀리면 이상인지를 정하려면 정상 구간의 값을 먼저 봐야 한다.
 * 문서 10.1절이 (미정) 으로 남겨 둔 항목이다. 지어내지 않는다.
 */
