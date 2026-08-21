# 배포

## 무엇이 어디 있나

| 것 | 어디 | 왜 |
|---|---|---|
| `scripts/preflight.sh` | 이 저장소 | G-RELEASE. 런타임 상태 조회라 LLM 이 판정할 수 없다 |
| `scripts/deploy.sh` | 이 저장소 | ASG 이름과 SSM 경로가 Terraform 이 정한 값이다 |
| `scripts/rollback.sh` | 이 저장소 | 이전 SHA 로 배포를 다시 하는 것뿐이다 |
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
10. 배치 교체              SSM SendCommand -> .env 의 GIT_SHA 갱신 -> systemctl restart
11. 최종 확인
```

**앱보다 뒤에 하는 이유는 스키마 확장 후 축소 때문이다.** 앱이 먼저 새 버전이 되어야 배치가 새 스키마를 전제해도 안전하다.

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

## 아직 안 되는 것

**backend 에 actuator 가 없다.** `/actuator/health/readiness` 가 404 라 대상 그룹이 healthy 가 되지 않는다. 지금 배포를 돌리면 5번 단계에서 상한까지 기다리다 실패한다.

필요한 것은 이렇다.

| 요구 | 현황 |
|---|---|
| `spring-boot-starter-actuator`, `micrometer-registry-prometheus` | 의존성 없음 |
| `management.server.port: 8081` | 설정 없음 |
| `management.endpoint.health.probes.enabled: true` | 설정 없음 |
| `server.shutdown: graceful` | 없음 |
| JDBC `connectTimeout=3000&socketTimeout=10000` | 없음 |
| Hikari 풀 설정 | 없음 |
| `SecurityConfig` 에 `/actuator/health/**` 공개 | 주석으로 예고만 |
| Dockerfile | **없음** |
