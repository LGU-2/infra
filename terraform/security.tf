/*
 * 앱이 퍼블릭 서브넷에 있으므로 보안은 서브넷이 아니라 보안 그룹이 확보한다.
 * 그래서 인바운드는 CIDR 이 아니라 보안 그룹 참조로만 연다. 인터넷을 받는 ALB 만 예외다.
 * 22번 포트는 어디에도 열지 않는다. 운영 접근은 SSM Session Manager 로 한다 (INF-12).
 */

locals {
  sg_names = {
    alb   = "인터넷을 받는 유일한 자리"
    app   = "8080 은 ALB, 8081 은 ALB 와 모니터링"
    db    = "앱, 배치, 모니터링이 들어온다"
    cache = "앱과 모니터링이 들어온다"
    mon   = "인바운드 없음"
    batch = "인바운드 없음"
    lt    = "인바운드 없음"
  }
}

resource "aws_security_group" "alb" {
  name        = "${var.project}-alb"
  description = local.sg_names.alb
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-alb"
  }
}

resource "aws_security_group" "app" {
  name        = "${var.project}-app"
  description = local.sg_names.app
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-app"
  }
}

resource "aws_security_group" "db" {
  name        = "${var.project}-db"
  description = local.sg_names.db
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-db"
  }
}

resource "aws_security_group" "cache" {
  name        = "${var.project}-cache"
  description = local.sg_names.cache
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-cache"
  }
}

resource "aws_security_group" "mon" {
  name        = "${var.project}-mon"
  description = local.sg_names.mon
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-mon"
  }
}

resource "aws_security_group" "batch" {
  name        = "${var.project}-batch"
  description = local.sg_names.batch
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-batch"
  }
}

resource "aws_security_group" "lt" {
  name        = "${var.project}-lt"
  description = local.sg_names.lt
  vpc_id      = aws_vpc.main.id

  tags = {
    Name = "${var.project}-lt"
  }
}

# 인터넷에서 들어오는 유일한 자리다. 80 은 리스너가 443 으로 넘긴다.
resource "aws_vpc_security_group_ingress_rule" "alb_https" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
  description       = "인터넷에서 오는 HTTPS"
}

resource "aws_vpc_security_group_ingress_rule" "alb_http" {
  security_group_id = aws_security_group.alb.id
  cidr_ipv4         = "0.0.0.0/0"
  from_port         = 80
  to_port           = 80
  ip_protocol       = "tcp"
  description       = "리스너가 443 으로 리다이렉트한다"
}

resource "aws_vpc_security_group_ingress_rule" "app_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8080
  to_port                      = 8080
  ip_protocol                  = "tcp"
  description                  = "ALB 가 대상 그룹으로 보내는 트래픽"
}

/*
 * 액추에이터를 8081 로 분리했다.
 * ALB 는 헬스체크를, Prometheus 는 /actuator/prometheus 를 여기로 찌른다.
 * 이 포트가 밖으로 열리면 관리 포트로 나눈 의미가 사라진다 (INF-12-21).
 */
resource "aws_vpc_security_group_ingress_rule" "app_mgmt_from_alb" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.alb.id
  from_port                    = 8081
  to_port                      = 8081
  ip_protocol                  = "tcp"
  description                  = "ALB 헬스체크와 liveness 경로"
}

# 이 규칙이 없으면 앱 지표가 통째로 사라진다.
resource "aws_vpc_security_group_ingress_rule" "app_mgmt_from_mon" {
  security_group_id            = aws_security_group.app.id
  referenced_security_group_id = aws_security_group.mon.id
  from_port                    = 8081
  to_port                      = 8081
  ip_protocol                  = "tcp"
  description                  = "Prometheus 스크랩"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_app" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "앱의 커넥션 풀"
}

# 배치가 DB 에 못 붙으면 아무 일도 못 한다.
resource "aws_vpc_security_group_ingress_rule" "db_from_batch" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.batch.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "배치의 커넥션 풀"
}

resource "aws_vpc_security_group_ingress_rule" "db_from_mon" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.mon.id
  from_port                    = 3306
  to_port                      = 3306
  ip_protocol                  = "tcp"
  description                  = "mysqld_exporter"
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_app" {
  security_group_id            = aws_security_group.cache.id
  referenced_security_group_id = aws_security_group.app.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "앱의 캐시 접근"
}

resource "aws_vpc_security_group_ingress_rule" "cache_from_mon" {
  security_group_id            = aws_security_group.cache.id
  referenced_security_group_id = aws_security_group.mon.id
  from_port                    = 6379
  to_port                      = 6379
  ip_protocol                  = "tcp"
  description                  = "redis_exporter"
}

/*
 * 아웃바운드는 전부 열어 둔다.
 * GHCR 이미지 pull, SSM Parameter Store 조회, 패키지 설치가 인터넷으로 나간다.
 * 프라이빗 서브넷의 RDS 와 캐시는 라우팅에 기본 경로가 없어 실제로는 나가지 못한다.
 */
resource "aws_vpc_security_group_egress_rule" "all" {
  for_each = {
    alb   = aws_security_group.alb.id
    app   = aws_security_group.app.id
    db    = aws_security_group.db.id
    cache = aws_security_group.cache.id
    mon   = aws_security_group.mon.id
    batch = aws_security_group.batch.id
    lt    = aws_security_group.lt.id
  }

  security_group_id = each.value
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "전체 허용"
}
