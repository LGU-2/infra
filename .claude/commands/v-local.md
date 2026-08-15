---
description: G-LOCAL. push 하지 않은 커밋의 변경분을 세 저장소의 점검 항목으로 판정한다
allowed-tools: Bash(./verify.sh*), Bash(git *), Read, Glob, Grep, Write
---

# G-LOCAL

저장소 루트의 `./verify.sh $ARGUMENTS` 를 돌리고, 그 출력의 판정 지시문을 따른다.

| 인자 | 범위 |
|---|---|
| 없음 | 아직 push 하지 않은 커밋 전부 |
| `HEAD` | 최신 커밋 1개 |
| `HEAD~5` | 최신 커밋 5개 |

스크립트가 기준 저장소를 찾고 빌드 게이트를 돌리고 판정 범위를 계산한다.
절차는 common 저장소의 `docs/verification/g-local.md` 에 있고 지시문이 그 문서를 가리킨다.

**이 파일은 편의 진입점일 뿐이다.** 다른 CLI 에이전트를 쓰는 팀원은 `./verify.sh` 를 직접 돌린다.
그래서 절차도 계산도 여기 두지 않는다.

종료 코드 `2` 는 기준 저장소를 못 찾은 것이다. 그때는 스크립트가 받는 방법을 알려주므로 사용자에게 물어본다.
