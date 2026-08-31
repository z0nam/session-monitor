# smon tokens — 다기계 토큰 사용량 집계

여러 기계에 흩어진 Claude Code 세션의 토큰 사용량을 **프로젝트 단위**로 모아
개인/업무로 나눠 보고, 손실 없는 CSV로 떨군다. 자주 확인할 용도.

```
smon tokens                 # 요약 테이블 + 오늘자 CSV (~/.local/share/smon/token-usage-YYYYMMDD.csv)
smon tokens --csv out.csv    # CSV 경로 지정
```

## 산출 과정 (어떻게 세나)

1. **원천**: 각 기계의 `~/.claude/projects/<cwd-인코딩>/*.jsonl`. 이 전사의 assistant
   메시지마다 `message.usage = {input_tokens, output_tokens,
   cache_creation_input_tokens, cache_read_input_tokens}` 가 있다. 프로젝트(=cwd)별로 이 넷을 합산.
   - 폴더별 첫 전사에서 `cwd` 를 한 번 읽어 사람이 읽는 경로/프로젝트명을 붙인다.
   - 내용이 완전히 같은 중복 슬러그(폴더 이동 등)는 한 번만 센다.
2. **수집**: `token-hosts.tsv` 의 각 host 에 `ssh host <python> - --local` 로 이 스크립트를
   stdin 파이프해 원격에서 `--local` 모드로 돌리고, 나온 JSON 을 모은다.
   `local` 인 항목은 이 기계에서 직접. **오프라인 기계는 자동으로 건너뛰고** 말미에 보고.
3. **분류**: `token-rules.tsv` 규칙을 위에서부터 적용(첫 매치 승). category 는 자유롭지만
   요약은 **개인 vs 업무** 축으로 집계. 규칙에 안 걸리면 기본 = 업무.
4. **산출**:
   - **CSV(무손실)**: `host, category, subcategory, project, cwd, total, input, output,
     cache_creation, cache_read, messages, files, note` — 기계×프로젝트 원자료라
     어떤 재집계도 스프레드시트에서 다시 할 수 있다(`total = input+output+cache_creation+cache_read`).
   - **요약**: 기계별·용도별·개인세부 테이블을 stdout 에.

## 설정 (개인정보라 레포 밖 로컬에)

- `~/.config/smon/token-hosts.tsv` ← `worker/token-hosts.example.tsv`
- `~/.config/smon/token-rules.tsv` ← `worker/token-rules.example.tsv`
- 경로 override: `SMON_TOKEN_HOSTS`, `SMON_TOKEN_RULES` 환경변수.

## 읽을 때 주의

- **총량의 대부분(~9할)은 `cache_read`** = 캐시 재사용분이라 실비가 아니라 **구독 사용량** 성격.
  순수 생성량을 보려면 `output` 열을 본다.
- **홈/`dev` 루트 세션**(`mixed_root`)은 여러 프로젝트가 한 폴더에서 섞여 돌아간 것이라
  폴더 단위로 완벽히 못 가른다. 이 버킷(예: 컴퓨터문제해결/잡무)엔 소량의 업무가 섞일 수 있다.
  정밀히 가르려면 CSV 를 열어 세션 요약(sessions.db)과 대조해 수동 조정.
- 원격 Windows 는 `python`, mac/linux 는 `python3` (hosts 파일의 pycmd 로 지정).
