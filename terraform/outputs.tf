# 배포 스크립트와 preflight 스크립트가 이 값들을 읽는다.

output "vpc_id" {
  description = "VPC ID"
  value       = aws_vpc.main.id
}

output "public_subnet_ids" {
  description = "퍼블릭 서브넷 ID. ASG 와 인스턴스가 쓴다"
  value       = { for k, s in aws_subnet.public : k => s.id }
}

output "private_subnet_ids" {
  description = "프라이빗 서브넷 ID. RDS 와 캐시 서브넷 그룹이 쓴다"
  value       = { for k, s in aws_subnet.private : k => s.id }
}

output "security_group_ids" {
  description = "역할별 보안 그룹 ID"

  value = {
    alb   = aws_security_group.alb.id
    app   = aws_security_group.app.id
    db    = aws_security_group.db.id
    cache = aws_security_group.cache.id
    mon   = aws_security_group.mon.id
    batch = aws_security_group.batch.id
    lt    = aws_security_group.lt.id
  }
}
