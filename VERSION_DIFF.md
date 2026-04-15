# fault_quickview 버전별 차이 설명

아래는 초기 Python 버전(v1)과 현재 Shell Script 버전(v2)의 코드 차이입니다.

## 요약

| 항목 | v1 (Python) | v2 (Shell Script) |
|---|---|---|
| 엔트리포인트 | `fault_quickview.py` | `fault_quickview.sh` |
| 파싱 구현 | `re`, `dataclass` 기반 함수 분리 | `bash` + `awk/sed/grep` 파이프라인 |
| 데이터 모델 | `TicketInfo`, `DiskFault`, `Summary` 등 구조화 | 문자열 row(`|` 구분) + 배열 기반 |
| JSON 생성 | `json.dumps` | 수동 문자열 조립 + escape 함수 |
| 원격 실행 | `subprocess.run(["ssh", ...])` | `ssh` 직접 호출 |
| 실행 의존성 | Python 3 런타임 필요 | Bash + 표준 유틸만 필요 |

## 상세 차이

### 1) 아키텍처
- **v1**은 함수/데이터클래스 중심으로 구조화되어 확장성이 좋음.
- **v2**는 운영 서버에 Python 설치가 없어도 동작하도록 Bash 단일 파일 중심으로 구현.

### 2) 파싱 방식
- **v1**: `parse_raidcheck`, `parse_mounts`, `parse_sel`로 책임이 명확함.
- **v2**: 동일 로직을 `while read` 루프와 정규식 매칭으로 구현.
  - RAID fault 슬롯 추출
  - mount 결합으로 교체 안전 여부(`SAFE/CHECK`) 계산
  - SEL에서 Memory/FAN/PSU만 분류

### 3) JSON 출력
- **v1**은 객체를 그대로 JSON 직렬화해서 안정적.
- **v2**는 외부 의존성(`jq`) 없이 동작하도록 수동 직렬화를 선택.
  - `json_escape`로 백슬래시/따옴표 처리

### 4) 운영 관점 트레이드오프
- **v2 장점**
  - 배포 간단(파일 1개)
  - 최소 의존성
- **v2 한계**
  - 복잡한 파싱/유닛테스트는 Python 대비 불리
  - JSON 직렬화 유지보수 비용 증가

## 왜 v2로 변경했는가
요구사항이 "파이썬말고 shellscript"였기 때문에, 동작 범위를 유지하면서 구현 언어를 Bash로 교체했습니다.

## 향후 개선 권장
- 벤더별 RAID 포맷이 다르면 `case` 분기(벤더 프로파일) 추가
- SEL 룰셋을 외부 파일(YAML/ini 대체로 key-value)로 분리
- CI에서 smoke test + 샘플 회귀 테스트 자동화
