#!/usr/bin/env bash
#
# 인프라를 올린다. bootstrap 을 먼저 돌리는 순서를 사람이 기억하지 않아도 되게 한다.
#
# 두 구성이 갈라져 있어 Terraform 이 순서를 세워 주지 못한다.
# 시크릿을 bootstrap 에 둔 것은 destroy 를 견디게 하려는 것이고(표준 파라미터라 유지 비용이 0 이다),
# 그 대가로 생긴 의존이 이 순서다. 여기서 흡수한다.
#
# bootstrap apply 는 멱등하다. 이미 적용되어 있으면 no-op 이므로 매번 돌려도 안전하다.
#
# 시크릿 검사를 여기서 하는 이유는 Terraform 이 db-password 하나만 보기 때문이다(rds.tf postcondition).
# 나머지 일곱은 unset 이어도 apply 가 통과하고, 인스턴스가 뜬 뒤에야 드러난다.
# GHCR 로그인 실패로 컨테이너가 안 뜨거나, Slack 알림이 조용히 안 가는 식이다.

set -euo pipefail

PROJECT="${PROJECT:-freshmarket}"
REGION="${AWS_REGION:-ap-northeast-2}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '[%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# 1. bootstrap. 상태 버킷과 시크릿 자리를 만든다.
log "1. bootstrap"
cd "$ROOT/bootstrap"

# 상태 파일이 로컬에만 있다. 다른 기계에서 클론하면 없다.
# 그대로 apply 하면 이미 있는 버킷을 다시 만들려다 BucketAlreadyOwnedByYou 로 죽는다.
# 에러를 만나기 전에 무엇을 해야 하는지 알려 준다.
if [ ! -f terraform.tfstate ] \
  && aws s3api head-bucket --bucket "tfstate-$PROJECT" --region "$REGION" 2>/dev/null; then
  die "$(cat <<EOF
bootstrap 상태 파일이 없는데 버킷 tfstate-$PROJECT 은 이미 있다.
다른 기계에서 만든 것이다. 상태는 gitignore 되어 따라오지 않는다.

  cd bootstrap
  terraform import aws_s3_bucket.tfstate tfstate-$PROJECT
  for k in jwt-signing-key db-password db-exporter-password github-token \\
           ghcr-token slack-webhook-critical slack-webhook-warning slack-webhook-watchdog; do
    terraform import "aws_ssm_parameter.secure[\\"\$k\\"]" "/$PROJECT/\$k"
  done
EOF
)"
fi

terraform init -input=false > /dev/null
terraform apply -auto-approve -input=false

# 2. 시크릿 여덟 개가 다 찼는지 본다.
log "2. 시크릿 확인"
unset_names=$(aws ssm get-parameters-by-path --path "/$PROJECT" --region "$REGION" \
  --with-decryption --query 'Parameters[?Value==`unset`].Name' --output text)

if [ -n "$unset_names" ]; then
  printf '아직 값이 없는 시크릿이 있다.\n\n'
  for n in $unset_names; do printf '  %s\n' "$n"; done
  printf '\n각각 이렇게 넣는다. 비밀번호에 $ 나 ! 가 들어갈 수 있으므로 작은따옴표를 쓴다.\n\n'
  printf "  aws ssm put-parameter --region %s --overwrite --type SecureString \\\\\n" "$REGION"
  printf "    --name %s --value '<값>'\n\n" "${unset_names%%$'\t'*}"
  printf '서명 키는 직접 정할 이유가 없다.\n\n'
  printf "  --value \"\$(openssl rand -base64 48)\"\n"
  exit 1
fi

# 3. 본 구성. 여기부터 과금이 시작된다.
log "3. terraform"
cd "$ROOT/terraform"
terraform init -input=false -backend-config=backend.hcl > /dev/null
terraform apply -input=false "$@"

echo
log "완료. 다음은 출력값을 GitHub 에 넣는 것이다"
log "  terraform output github_role_arns   deploy 값을 fm-backend 의 AWS_DEPLOY_ROLE_ARN 변수로"
log "  terraform output cdn_domain         앱의 cdn.base-url 로"
