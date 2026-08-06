# 인프라 검증 가이드라인

이 디렉터리는 `docs/system-design/`의 설계 결정 중 **점검 가능한 것**을 추출해 정리한다.
이 문서(INFRAREVIEW.md)는 진입점이며, 분류 기준과 각 문서로의 링크를 담는다.

## 왜 별도 디렉터리인가

`docs/system-design/`의 9개 문서는 **왜 그렇게 정했는지**를 담는다. 설계 근거, 대안 비교, 확정값, 포기한 것이 함께 있다.
점검 항목이 그 안에 표와 절차로 흩어져 있어 기계가 읽을 수 없고 사람도 어디를 봐야 할지 알기 어렵다.

이 디렉터리는 그중 판정 가능한 것만 뽑아 형식을 통일한다.
**system-design 문서는 수정하지 않는다.** 저쪽이 rationale, 이쪽이 guideline 역할이다.
`LGU-2/backend`의 `docs/code-architecture/`가 guideline과 rationale을 짝지은 것과 같은 구조다.

## 문서 구성

판정 주체가 다르면 문서를 나눈다. 한곳에 모으면 스크립트가 할 일과 사람이 할 일이 섞여 둘 다 실행되지 않는다.

| 문서 | 판정 주체 | 판정 시점 | 게이트 |
|------|-----------|-----------|--------|
| [code-guideline.md](./code-guideline.md) | LLM | PR diff | **G-PR** |
| [preflight-guideline.md](./preflight-guideline.md) | 배포와 시험 스크립트 | 실행 직전 | G-RELEASE |
| [operation-guideline.md](./operation-guideline.md) | 사람 | 일회성 결정, 주기적 시험 | G-AUDIT (기록 확인만) |

## 분류 기준

| 질문 | 예 | 분류 |
|------|-----|------|
| 파일을 읽어 판정할 수 있는가 | "TTL이 배치 주기보다 짧은가" | code |
| 런타임 상태를 조회해야 하는가 | "RDS가 available인가" | preflight |
| 사람의 판단이나 시험 수행이 필요한가 | "부하 시험에서 앱이 병목으로 확인되었는가" | operation |

**경계가 애매하면 code로 보낸다.** 자동 판정을 시도해 보고 안 되면 그때 옮기는 편이, 처음부터 사람에게 맡겨 아무도 보지 않는 것보다 낫다.

## 판정 대상이 이 저장소에만 있지 않다

`code-guideline.md`의 항목 대부분은 **`LGU-2/backend`의 코드가 판정 대상**이다.
인프라 결정이 애플리케이션 코드에 부과하는 제약이기 때문이다.

```
분산 락 TTL         -> backend 의 @Scheduled 코드
Hikari 타임아웃      -> backend 의 application.yml
readiness 그룹      -> backend 의 application.yml
스키마 확장 후 축소   -> backend 의 db/migration/*.sql
```

Terraform과 k8s manifest가 판정 대상인 항목은 아직 없다. **이 저장소에 실행 가능한 산출물이 없기 때문이다.**
Terraform 구성이 만들어지면 그때 `code-guideline.md`에 인프라 코드 점검 절을 추가하고 이 저장소의 `anchors.yml`을 만든다.

## 다른 저장소와의 경계

| 저장소 | 다루는 것 |
|--------|-----------|
| `LGU-2/.github` | 일반 품질 속성. "얼마나 잘 하는가" (성능, 신뢰성, 보안 등 217건) |
| `LGU-2/backend` | 코드 관용과 패턴. "어떻게 쓰는가" (250건) |
| **`LGU-2/infra`** | **이 인프라의 확정 결정이 코드에 부과하는 제약** |

겹칠 때의 소유 기준은 **더 구체적이고 근거가 강한 쪽**이다.

| 사안 | 소유 |
|------|------|
| 타임아웃이 설정되어 있는가 (일반) | `.github`의 `REL-2-*` |
| 타임아웃 값이 확정값과 일치하는가 | **이 저장소** |
| 트랜잭션 안에서 외부 API를 호출하지 않는가 | `.github`의 `DI-4-*` |
| 배치 상태 전이가 조건부 UPDATE인가 | **이 저장소** |

일반 기준은 `.github`이 갖고, **이 인프라에서만 성립하는 제약**을 여기가 갖는다.
