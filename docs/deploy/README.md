# 배포

## 무엇이 어디 있나

| 것 | 어디 | 왜 |
|---|---|---|
| `scripts/preflight.sh` | 이 저장소 | G-RELEASE. 런타임 상태 조회라 LLM 이 판정할 수 없다 |
| `scripts/deploy.sh` | 이 저장소 | ASG 이름과 SSM 경로가 Terraform 이 정한 값이다 |
| `scripts/rollback.sh` | 이 저장소 | 이전 SHA 로 배포를 다시 하는 것뿐이다 |
| `scripts/stop.sh` `start.sh` | 이 저장소 | 세션 단위로 껐다 켠다 |
| `scripts/destroy.sh` | 이 저장소 | 전부 지운다 |
| `backend-deploy-workflow.yml` | 이 저장소가 원본 | fm-backend 에 복사해서 쓴다 |

배포 절차가 인프라 결정에서 나오므로 원본을 여기 둔다. backend 워크플로가 `actions/checkout` 으로 받아 쓴다. `llm-verify` 가 형제 저장소를 받아 쓰는 것과 같은 방식이다.

## main 병합 시에만 배포한다

세 겹으로 걸린다.

```
1. git-convention   팀원은 develop 으로만 PR 을 연다. main 은 관리자의 릴리스 PR 뿐이다
2. 워크플로 트리거   on: push: branches: [main]
3. AWS 신뢰 정책     repo:fresh-market/fm-backend:ref:refs/heads/main
```

**3번이 결정적이다.** 워크플로 파일을 고쳐 다른 브랜치에서 돌려도 STS 가 자격증명을 주지 않는다. 파일 수정으로 뚫리지 않는다.

## 배치는 앱 뒤에 교체한다

`deploy.sh` 10번 단계다. 배치는 ASG 밖이라 `desired` 로 다룰 수 없어 SSM 으로 서비스를 재시작한다.

```
9.  앱 구 인스턴스 종료
10. 배치 교체              SSM SendCommand -> refresh-env -> systemctl stop/start
11. 최종 확인
```

**앱보다 뒤에 하는 이유는 스키마 확장 후 축소 때문이다.** 앱이 먼저 새 버전이 되어야 배치가 새 스키마를 전제해도 안전하다.

**`.env` 를 통째로 다시 만든다.** `GIT_SHA` 한 줄만 고치지 않는다. user-data 는 최초 부팅에만 돌아서 나머지 값이 부팅 시점에 굳는데, RDS 복원은 항상 새 인스턴스를 만들어 엔드포인트가 바뀐다(`INF-26`). 부분 수정으로는 배치가 그 변화를 영원히 따라가지 못한다.

`refresh-env` 는 `terraform/templates/refresh-env.sh.tftpl` 에서 나오고 user-data 가 부팅 때 인스턴스에 심는다. **부팅과 재배포가 같은 코드를 쓴다**(`MNT-3-01`).

**롤링으로 하지 않는다.** 구버전과 신버전 배치가 겹치면 "프로세스는 항상 하나" 라는 전제가 깨지고, 분산 락이 없어 아무것도 막지 못한다. 그래서 중지 후 시작이다.

배치 교체가 실패하면 **앱은 이미 새 버전이고 배치만 옛 버전인 구간**이 남는다. 스크립트가 그 사실을 로그로 남기고 종료 코드 1로 끝낸다. 되돌리지 않는 이유는, 배치만 옛 버전인 상태가 앱까지 되돌리는 것보다 대개 덜 위험하기 때문이다.

## Terraform 과 스크립트의 경계

| 대상 | 누가 |
|---|---|
| ASG, 시작 템플릿, 대상 그룹, 리스너 | Terraform |
| **SSM 파라미터 리소스** | Terraform |
| **SSM 파라미터의 값** | **스크립트** |
| **desired capacity** | **스크립트** |
| 대상 등록과 해제 | 스크립트 |

Terraform 이 값이나 desired 를 건드리면 배포가 깨진다. 그래서 `ignore_changes` 를 걸어 두었다.

## 처음 적용할 때

```bash
# 1. 상태 버킷
cd bootstrap && terraform init && terraform apply

# 2. 시크릿을 채운다. 이걸 빼먹으면 3번이 precondition 에서 막힌다.
for name in db-password db-exporter-password github-token \
            jwt-signing-key slack-webhook-critical slack-webhook-warning slack-webhook-watchdog; do
  aws ssm put-parameter --name "/freshmarket/$name" --type SecureString \
    --value "<값>" --overwrite
done

# 3. 인프라
cd ../terraform && terraform init -backend-config=backend.hcl && terraform apply

# 4. 출력값을 GitHub 에 넣는다
terraform output github_role_arns   # deploy 값을 fm-backend 의 AWS_DEPLOY_ROLE_ARN 변수로
terraform output cdn_domain         # 앱의 cdn.base-url 로

# 5. 워크플로를 backend 에 복사한다
cp docs/deploy/backend-deploy-workflow.yml ../backend/.github/workflows/deploy.yml
```

## 세션 단위로 껐다 켠다

상시 가동이 필요 없을 때 쓴다.

```bash
./scripts/stop.sh     # ASG desired 0 -> 모니터링/배치 중지 -> RDS 중지
./scripts/start.sh    # RDS 와 인스턴스 시작 -> 엔드포인트 갱신 -> desired 1 -> healthy 대기
```

**중지로는 절반밖에 못 줄인다.** ALB 와 ElastiCache 는 중지라는 개념이 없어 이 둘만으로 월 약 29 USD 가 계속 나간다.

`stop.sh` 가 앱부터 내리는 것은 의존 방향 때문이다. RDS 를 먼저 내리면 커넥션 오류가 마지막 구간의 지표를 오염시킨다. 모니터링과 배치는 ASG 밖이라 `desired` 가 아니라 `stop-instances` 로 다룬다. 앱을 `stop-instances` 로 내리면 ASG 가 비정상으로 보고 교체해 세션이 끝나지 않는다(`INF-23`).

**RDS 중지는 최대 7일이다.** 그 뒤 자동으로 다시 시작되므로 주 1회 이상 다시 내려야 한다.

## 전부 지운다

오래 안 쓸 때 쓴다.

```bash
./scripts/destroy.sh            # 계정 ID 를 직접 입력해야 진행된다
./scripts/destroy.sh --yes      # 확인을 건너뛴다
```

`terraform destroy` 만으로는 되지 않는다. 세 겹이 막는다.

| 막는 것 | 어디서 거부되나 |
|---|---|
| `lifecycle { prevent_destroy }` 5곳 | Terraform 이 plan 단계에서 |
| `deletion_protection` (RDS, ALB) | AWS 가 API 호출을 |
| `skip_final_snapshot = false` | RDS 가 스냅샷 이름을 요구하며 |

그래서 스크립트가 **가드를 걷어내고 apply 를 한 번 돌린 뒤에야** destroy 한다. 삭제 보호는 코드만 고쳐서는 안 꺼지고 AWS 에 반영되어야 한다.

걷어낸 가드는 `trap` 으로 **반드시 되돌린다.** 중간에 실패해도 마찬가지다. 방어가 코드에 살아 있어야 다음 재구축이 안전하다. 그래서 가드 파일에 커밋 안 된 변경이 있으면 시작하지 않는다. 원복이 그것까지 되돌리기 때문이다.

**destroy 가 끝나도 EBS 볼륨이 남는다.** `delete_on_termination = false` 인 모니터링 루트 볼륨이다. 관측 데이터를 지키려는 설정이라 Terraform 이 일부러 안 지운다. 스크립트가 따로 찾아 지운다.

남는 것 셋은 정상이다.

- **KMS 키 3개** (`aws/ebs`, `aws/rds`, `aws/ssm`). AWS 관리형이라 무료이고 삭제할 수 없다
- **tfstate 버킷**. `bootstrap/` 소관이라 대상이 아니고 재구축에 그대로 쓴다
- **IAM 역할이 0 이 아니면** Terraform 밖에서 만든 것이다. 콘솔 활동의 잔재일 수 있다

마지막에 `terraform state` 가 아니라 **AWS 에 직접 조회해** 잔여를 센다. 상태와 실제가 어긋날 수 있다.
