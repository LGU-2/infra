/*
 * NAT Gateway 를 쓰지 않는다 (INF-09).
 * 시간당 요금과 데이터 처리 요금이 이중으로 붙어 월 40 USD 를 넘고, 그것은 전체 예산의 4분의 1이다.
 * 그래서 앱이 퍼블릭 서브넷에 있고 보안은 보안 그룹이 확보한다.
 */

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = {
    Name = "${var.project}-vpc"
  }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-igw"
  }
}

# ALB, 앱, 모니터링, 배치, 부하 생성이 여기 있다.
resource "aws_subnet" "public" {
  for_each = var.public_subnet_cidrs

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = var.azs[each.key]

  # NAT 가 없으므로 인스턴스가 퍼블릭 IP 로 직접 나간다.
  map_public_ip_on_launch = true

  tags = {
    Name = "${var.project}-public-${each.key}"
    Tier = "public"
  }
}

# RDS 와 ElastiCache 가 여기 있다. 나갈 일이 없다.
resource "aws_subnet" "private" {
  for_each = var.private_subnet_cidrs

  vpc_id            = aws_vpc.main.id
  cidr_block        = each.value
  availability_zone = var.azs[each.key]

  tags = {
    Name = "${var.project}-private-${each.key}"
    Tier = "private"
  }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = {
    Name = "${var.project}-public"
  }
}

/*
 * 기본 경로를 두지 않는다.
 * NAT 가 없어 나갈 길이 없고, RDS 와 캐시는 나갈 일도 없다.
 * VPC 내부 통신은 로컬 경로로 자동 처리된다.
 */
resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  tags = {
    Name = "${var.project}-private"
  }
}

resource "aws_route_table_association" "public" {
  for_each = aws_subnet.public

  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "private" {
  for_each = aws_subnet.private

  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}
