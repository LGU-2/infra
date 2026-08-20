#!/usr/bin/env bash
#
# 인스턴스 단위 롤링 배포. 절차는 docs/system-design/백엔드공통_무중단배포_롤링.md 6절이다.
#
# 신규를 먼저 띄우고 검증한 뒤 구 인스턴스를 지운다.
# 그래서 배포 중 용량이 100% 로 유지되고, 실패해도 구 버전이 계속 서비스한다.
#
# Terraform 이 하지 않는 일을 여기서 한다.
# SSM 값 갱신, desired 조정, 대상 등록 해제가 그것이다. 경계는 무중단배포 5절에 있다.
#
#   ./deploy.sh <커밋 SHA>

set -euo pipefail

PROJECT="${PROJECT:-freshmarket}"
REGION="${AWS_REGION:-ap-northeast-2}"
SHA="${1:?배포할 커밋 SHA 를 넘겨라}"
ASG="$PROJECT-app"

# 신규가 healthy 가 될 때까지 기다리는 상한. 기동이 4~6분이라 여유를 둔다.
HEALTHY_TIMEOUT=360

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

tg_arn=$(aws elbv2 describe-target-groups --names "$PROJECT-app" \
  --region "$REGION" --query 'TargetGroups[0].TargetGroupArn' --output text)

healthy_count() {
  aws elbv2 describe-target-health --target-group-arn "$tg_arn" --region "$REGION" \
    --query 'length(TargetHealthDescriptions[?TargetHealth.State==`healthy`])' --output text
}

instance_ids() {
  aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
    --region "$REGION" --query 'AutoScalingGroups[0].Instances[].InstanceId' --output text
}

# 0. 사전 상태 점검. 실패하면 여기서 끝난다.
log "0. 사전 점검"
"$(dirname "$0")/preflight.sh" deploy

# 1. 이미지는 워크플로가 이미 GHCR 에 올렸다. 여기서는 존재만 전제한다.
log "1. 이미지 태그 $SHA"

# 2. SSM 을 먼저 갱신한다.
#    교체보다 먼저여야 신규 인스턴스가 새 버전으로 뜬다. 순서가 뒤바뀌면 구 버전이 올라온다.
log "2. SSM current-sha 갱신"
aws ssm put-parameter --name "/$PROJECT/current-sha" --value "$SHA" \
  --type String --overwrite --region "$REGION" > /dev/null

# 3. 구 인스턴스 목록을 기록한다. 나중에 이것만 지운다.
old_ids=$(instance_ids)
log "3. 구 인스턴스: $old_ids"

before=$(healthy_count)
desired=$(aws autoscaling describe-auto-scaling-groups --auto-scaling-group-names "$ASG" \
  --region "$REGION" --query 'AutoScalingGroups[0].DesiredCapacity' --output text)

# 4. desired 를 하나 올린다. 신규는 2번에서 갱신한 SHA 로 뜬다.
log "4. desired $desired -> $((desired + 1))"
aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" \
  --desired-capacity "$((desired + 1))" --region "$REGION"

# 5. 신규가 healthy 가 될 때까지 기다린다.
log "5. healthy 대기 (상한 ${HEALTHY_TIMEOUT}초)"
deadline=$(( $(date +%s) + HEALTHY_TIMEOUT ))
while [ "$(healthy_count)" -le "$before" ]; do
  if [ "$(date +%s)" -ge "$deadline" ]; then
    log "실패. 신규가 healthy 가 되지 않았다. 구 버전은 그대로 서비스 중이다."
    log "desired 를 되돌린다."
    aws autoscaling set-desired-capacity --auto-scaling-group-name "$ASG" \
      --desired-capacity "$desired" --region "$REGION"
    exit 1
  fi
  sleep 10
done
log "   healthy $(healthy_count)"

# 6, 7. 스모크 테스트.
#      신규 인스턴스에 직접 찌르고 도메인으로도 찌른다.
#      직접 찌르는 이유는 ALB 를 거치면 어느 인스턴스가 답했는지 알 수 없기 때문이다.
new_ids=$(comm -13 <(echo "$old_ids" | tr '\t' '\n' | sort) <(instance_ids | tr '\t' '\n' | sort))
for id in $new_ids; do
  ip=$(aws ec2 describe-instances --instance-ids "$id" --region "$REGION" \
    --query 'Reservations[0].Instances[0].PrivateIpAddress' --output text)
  log "6. 스모크 (인스턴스 직접) $id $ip"
  if ! curl -fsS --max-time 5 "http://$ip:8081/actuator/health/readiness" > /dev/null; then
    log "실패. 신규만 종료하고 구 버전을 유지한다."
    aws autoscaling terminate-instance-in-auto-scaling-group --instance-id "$id" \
      --should-decrement-desired-capacity --region "$REGION" > /dev/null
    exit 1
  fi
done

if [ -n "${SMOKE_URL:-}" ]; then
  log "7. 스모크 (ALB 경유) $SMOKE_URL"
  curl -fsS --max-time 10 "$SMOKE_URL" > /dev/null
fi

# 9. 3번에서 기록한 구 인스턴스만 종료한다.
#    desired 를 함께 줄여 원래 대수로 돌아간다.
for id in $old_ids; do
  log "9. 구 인스턴스 종료 $id"
  aws autoscaling terminate-instance-in-auto-scaling-group --instance-id "$id" \
    --should-decrement-desired-capacity --region "$REGION" > /dev/null
done

# 10. 최종 확인
log "10. 최종 healthy $(healthy_count) / desired $desired"
log "배포 완료 $SHA"
