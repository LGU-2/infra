/*
 * 삭제 방지를 두 겹으로 건다 (INF-18, 되돌릴 수 없음).
 * 잘못된 변수 파일로 destroy 를 돌리면 ALB 가 사라지고 DNS 이름이 바뀐다.
 */
resource "aws_lb" "main" {
  name               = "${var.project}-alb"
  load_balancer_type = "application"
  subnets            = [for s in aws_subnet.public : s.id]
  security_groups    = [aws_security_group.alb.id]

  # 요청 타임아웃 계층의 가장 바깥이다. 안쪽이 더 짧아야 한다.
  idle_timeout = 60

  enable_deletion_protection = true

  tags = {
    Name = "${var.project}-alb"
  }

  lifecycle {
    prevent_destroy = true
  }
}

/*
 * 트래픽은 8080 으로 보내고 헬스체크만 8081 로 찌른다.
 * 액추에이터를 관리 포트로 뺐으므로 8080 에는 그 경로가 존재하지 않는다.
 *
 * readiness 를 본다. liveness 가 아니다.
 * readiness 에는 공유 의존성을 넣지 않는다 (INF-16). DB 가 흔들릴 때 전 인스턴스가 동시에 빠지는 것을 막는다.
 */
resource "aws_lb_target_group" "app" {
  name        = "${var.project}-app"
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  # 종료 타임아웃 계층의 가장 안쪽이다. Spring graceful 30초와 짝을 이룬다.
  deregistration_delay = 30

  health_check {
    path                = "/actuator/health/readiness"
    port                = "8081"
    protocol            = "HTTP"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Name = "${var.project}-app"
  }
}

/*
 * Route 53 헬스체크가 AWS 밖에서 liveness 를 찌른다 (INF-19).
 * Prometheus 는 VPC 안이라 ALB 가 죽어도 앱 지표는 정상으로 보인다. 그 사각지대를 메우는 눈이다.
 * 그 경로만 8081 로 보내려면 대상 그룹이 하나 더 있어야 한다.
 *
 * 이 대상 그룹이나 아래 규칙이 지워지면 외부 감시가 실패해 알람이 울린다.
 * 액추에이터가 열리는 방향으로는 고장 나지 않는다.
 */
resource "aws_lb_target_group" "liveness" {
  name        = "${var.project}-liveness"
  port        = 8081
  protocol    = "HTTP"
  vpc_id      = aws_vpc.main.id
  target_type = "instance"

  deregistration_delay = 30

  health_check {
    path                = "/actuator/health/liveness"
    protocol            = "HTTP"
    interval            = 10
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 2
    matcher             = "200"
  }

  tags = {
    Name = "${var.project}-liveness"
  }
}

# 도메인이 없으면 80 이 그대로 서비스한다. 임시 상태다.
resource "aws_lb_listener" "http" {
  load_balancer_arn = aws_lb.main.arn
  port              = 80
  protocol          = "HTTP"

  dynamic "default_action" {
    for_each = local.has_domain ? [1] : []

    content {
      type = "redirect"

      redirect {
        port        = "443"
        protocol    = "HTTPS"
        status_code = "HTTP_301"
      }
    }
  }

  dynamic "default_action" {
    for_each = local.has_domain ? [] : [1]

    content {
      type             = "forward"
      target_group_arn = aws_lb_target_group.app.arn
    }
  }
}

resource "aws_lb_listener" "https" {
  count = local.has_domain ? 1 : 0

  load_balancer_arn = aws_lb.main.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-2021-06"
  certificate_arn   = aws_acm_certificate_validation.main[0].certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }
}

locals {
  # 도메인 유무에 따라 규칙을 걸 리스너가 달라진다
  public_listener_arn = local.has_domain ? aws_lb_listener.https[0].arn : aws_lb_listener.http.arn
}

/*
 * liveness 하나만 8081 로 보낸다.
 * show-details 가 never 라 응답은 status 뿐이고 드러나는 정보가 없다.
 * 나머지 액추에이터 경로는 규칙이 없어 8080 으로 가고, 거기에는 존재하지 않아 404 다.
 */
resource "aws_lb_listener_rule" "liveness" {
  listener_arn = local.public_listener_arn
  priority     = 10

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.liveness.arn
  }

  condition {
    path_pattern {
      values = ["/actuator/health/liveness"]
    }
  }
}
