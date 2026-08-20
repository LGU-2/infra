/*
 * ElastiCache Valkey 9.0 (INF-03).
 * Redis OSS 가 아닌 이유는 ElastiCache 의 Redis OSS 가 7.1 에서 동결됐기 때문이다.
 * 9.0 인 이유는 해시 필드 만료가 거기서 들어왔기 때문이다.
 *
 * 단일 노드라도 replication_group 으로 만든다 (INF-36).
 * 복제본 추가는 replication group 에만 되고, 나중에 바꾸려면 이관이 필요하다.
 * 지금 정하면 비용 차이가 0 이다.
 */

# AZ-a 만 등록하면 나중에 Multi-AZ 를 켤 때 서브넷 그룹부터 고쳐야 한다.
resource "aws_elasticache_subnet_group" "main" {
  name        = "${var.project}-cache"
  description = "프라이빗 서브넷 2 AZ. 복제본을 붙일 자리를 미리 만든다"
  subnet_ids  = [for s in aws_subnet.private : s.id]
}

resource "aws_elasticache_parameter_group" "main" {
  name        = "${var.project}-valkey90"
  family      = "valkey9"
  description = "기본값을 쓴다. 캐시 용도라 조정할 것이 없다"

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_elasticache_replication_group" "main" {
  replication_group_id = "${var.project}-cache"
  description          = "조회 캐시. 평상시 Degradable 등급이다"

  engine         = "valkey"
  engine_version = "9.0"
  node_type      = var.cache_node_type
  port           = 6379

  /*
   * 평상시 노드 1대다 (INF-04).
   * 캐시가 판정 주체가 되는 구간에만 복제본을 붙이고 Multi-AZ 를 켠다.
   */
  num_cache_clusters         = 1
  automatic_failover_enabled = false
  multi_az_enabled           = false

  # 복제본을 붙일 때 이 값이 AZ-c 로 늘어난다.
  preferred_cache_cluster_azs = [var.azs["a"]]

  subnet_group_name    = aws_elasticache_subnet_group.main.name
  security_group_ids   = [aws_security_group.cache.id]
  parameter_group_name = aws_elasticache_parameter_group.main.name

  at_rest_encryption_enabled = true

  /*
   * 전송 암호화를 켜지 않는다.
   * 켜면 클라이언트가 TLS 로 붙어야 하는데 지금 앱에 캐시 클라이언트 자체가 없다.
   * 같은 VPC 안이고 보안 그룹이 앱과 모니터링만 허용한다.
   */
  transit_encryption_enabled = false

  maintenance_window       = "sun:20:30-sun:21:30"
  snapshot_retention_limit = 0

  /*
   * 9.0 에서 9.1 로 올라가지 못하게 한다.
   * 기술 스택 3.2절이 "9-alpine 을 쓰면 안 된다. 그 태그는 9.1 로 풀린다" 고 못 박았다.
   * 로컬 이미지를 9.0 으로 고정해 두고 운영만 올라가면 동작이 갈린다.
   */
  auto_minor_version_upgrade = false

  tags = {
    Name = "${var.project}-cache"
  }
}
