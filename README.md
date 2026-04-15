# IDC Fault Quickview (Shell Script)

`fault_quickview.sh`는 FLT 번호를 기준으로 장애 요약을 만들어 IDC 운영자가 교체 대상 부품만 빠르게 확인할 수 있게 해주는 Bash CLI 도구입니다.

## 기능
- 티켓 DB(FLT→호스트/OOB/랙) 조회
- RAID 출력에서 실패/누락 디스크 슬롯만 추출
- mount 상태 결합으로 JBOD 교체 위험 여부 표시
- IPMI SEL 로그에서 Memory/FAN/PSU fault만 추출
- 사람이 보기 쉬운 텍스트 또는 JSON 출력

## 빠른 실행
```bash
./fault_quickview.sh \
  --flt FLT-1001 \
  --ticket-db sample/tickets.csv \
  --raid-file sample/raidcheck.txt \
  --mount-file sample/mounts.txt \
  --sel-file sample/sel.txt
```

JSON 출력:
```bash
./fault_quickview.sh \
  --flt FLT-1001 \
  --ticket-db sample/tickets.csv \
  --raid-file sample/raidcheck.txt \
  --mount-file sample/mounts.txt \
  --sel-file sample/sel.txt \
  --json
```

## 운영 환경 연결
샘플 파일 대신 원격 명령을 사용할 수 있습니다.

- RAID: `--raid-cmd` (기본 `/usr/local/bin/raidcheck.sh`)
- Mount: `--mount-cmd` (기본 `mount`)
- SEL: `--sel-cmd` (기본 `ipmitool sel list`)

`--ssh-user`를 지정하면 `ssh user@host` 방식으로 명령을 실행합니다.

## 버전별 차이 설명
상세 비교는 `VERSION_DIFF.md`를 참고하세요.
