#!/usr/bin/env bash
#
# 세션 종료. 기술 스택 확정 문서 부록 A.4 절차를 그대로 옮겼다.
#
# 순서가 의존 방향에서 나온다. 의존하는 쪽(앱)부터 내린다.
# 앱보다 RDS 를 먼저 내리면 커넥션 오류가 마지막 구간의 지표를 오염시킨다.
#
# 중지로는 절반밖에 못 줄인다. ALB 와 ElastiCache 는 중지가 불가능해
# 이 둘만으로 월 약 29 USD 가 계속 나간다. 오래 안 쓸 거면 파괴 방식을 쓴다.

set -euo pipefail

PROJECT="${PROJECT:-freshmarket}"
REGION="${AWS_REGION:-ap-northeast-2}"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

# 1. 앱을 먼저 내린다.
#    stop-instances 를 쓰면 ASG 가 비정상으로 보고 교체해 세션을 끝낼 수 없다 (INF-23).
log "1. ASG desired 0"
aws autoscaling set-desired-capacity \
  --auto-scaling-group-name "$PROJECT-app" \
  --desired-capacity 0 --region "$REGION"

# 2. 관측 데이터 내보내기는 사람이 판단한다.
#    모니터링 인스턴스는 stop 이라 EBS 가 남지만, 인스턴스를 잃을 상황에 대비한 안내다.
log "2. 관측 데이터를 남길 것이 있으면 지금 내보낸다 (건너뛰려면 Enter)"
if [ -t 0 ]; then read -r _; fi

# 3. 모니터링은 ASG 밖이라 stop 으로 다룬다.
#    desired 0 은 EBS 까지 지워 Prometheus 와 Loki 데이터가 사라진다 (INF-24).
mon_id=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Role,Values=monitoring" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$mon_id" != "None" ] && [ -n "$mon_id" ]; then
  log "3. 모니터링 인스턴스 중지 $mon_id"
  aws ec2 stop-instances --instance-ids "$mon_id" --region "$REGION" > /dev/null
else
  log "3. 모니터링 인스턴스가 이미 내려가 있다"
fi

# 배치도 ASG 밖이다. 스케줄러가 도는 채로 두면 DB 가 켜져 있지 않아 계속 실패한다.
batch_id=$(aws ec2 describe-instances --region "$REGION" \
  --filters "Name=tag:Role,Values=batch" "Name=instance-state-name,Values=running" \
  --query 'Reservations[0].Instances[0].InstanceId' --output text)
if [ "$batch_id" != "None" ] && [ -n "$batch_id" ]; then
  log "3. 배치 인스턴스 중지 $batch_id"
  aws ec2 stop-instances --instance-ids "$batch_id" --region "$REGION" > /dev/null
fi

# 4. RDS 를 마지막에 내린다. 완료를 기다릴 필요는 없다.
#    최대 7일 뒤 자동으로 다시 시작되므로 주 1회 이상 재중지가 필요하다.
status=$(aws rds describe-db-instances --db-instance-identifier "$PROJECT-db" \
  --region "$REGION" --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null || echo missing)
if [ "$status" = "available" ]; then
  log "4. RDS 중지"
  aws rds stop-db-instance --db-instance-identifier "$PROJECT-db" --region "$REGION" > /dev/null
  log "   최대 7일 뒤 자동 시작된다. 그 전에 다시 내려야 한다"
else
  log "4. RDS 상태가 $status 라 건너뛴다"
fi

echo
log "중지 완료. ALB 와 ElastiCache 는 중지가 불가능해 계속 과금된다"
