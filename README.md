# Bedrock Usage CLI

AWS Bedrock 사용량을 모델별, 사용자별, 비용별로 간편하게 조회하는 Shell Script 도구입니다.

A Shell Script tool for easily querying AWS Bedrock usage by model, user, and cost.

---

## 주요 기능 / Features

| 커맨드 / Command | 설명 / Description |
|---|---|
| `overview` | 전체 요약 + 모델별 상세 + 일별 추이를 한 번에 조회 / Summary + per-model breakdown + daily trend in one pass |
| `users` | 사용자별 호출 횟수, 주 사용 모델, 클라이언트 분석 / Per-user invocations, top model & client |
| `cost` | 일별/월별 Bedrock 비용 분석 / Daily/monthly cost breakdown |

### 데이터 소스 / Data Sources

- **overview** — CloudWatch Metrics (`AWS/Bedrock` 네임스페이스)
- **users** — CloudTrail (`InvokeModel`, `InvokeModelWithResponseStream`, `ConverseStream` 이벤트)
- **cost** — AWS Cost Explorer (`BlendedCost`, `USAGE_TYPE` 기준 그룹핑)

---

## 사전 요구사항 / Prerequisites

- **AWS CLI** (v1 또는 v2 / v1 or v2)
- **jq** (JSON 처리 / JSON processor)
- **bc** (수학 연산 / math calculations)
- AWS 자격 증명이 설정되어 있어야 합니다 / AWS credentials must be configured

```bash
# macOS에서 설치 / Install on macOS
brew install awscli jq bc

# Linux (Debian/Ubuntu)
sudo apt install awscli jq bc
```

---

## 설치 / Installation

```bash
git clone <repository-url> bedrock-usage
cd bedrock-usage
chmod +x bedrock-usage.sh
```

또는 파일을 직접 복사한 후 실행 권한을 부여하세요.
Or copy the files directly and grant execute permission.

---

## 사용법 / Usage

```
./bedrock-usage.sh [옵션/options] <서브커맨드/subcommand>
```

### 공통 옵션 / Common Options

| 옵션 / Option | 설명 / Description | 기본값 / Default |
|---|---|---|
| `-r`, `--region` | AWS 리전 / AWS region | `us-east-1` |
| `-d`, `--days` | 조회 기간 (일) / Lookback period in days | `7` |
| `-o`, `--output` | 출력 형식 / Output format: `table`, `json`, `csv` | `table` |
| `-h`, `--help` | 도움말 출력 / Show help | - |

---

## 실행 예시 / Examples

### overview — 전체 현황 / Full Overview

요약, 모델별 상세, 일별 추이를 한 번의 API 조회로 출력합니다.
Shows summary, per-model breakdown, and daily trend in a single API pass.

```bash
./bedrock-usage.sh overview
./bedrock-usage.sh overview --days 14
```

```
=== Bedrock Usage Summary (2026-02-05 ~ 2026-02-12) ===

  Total Invocations:             2,964
  Total Input Tokens:          413,130
  Total Output Tokens:       1,622,971
  Active Models:                     6

Model                                   Invocations    Input Tokens    Output Tokens
──────────────────────────────────────────────────────────────────────────────────────
claude-opus-4-6                         1,215          5,618           868,329
claude-sonnet-4-5                       1,087          8,275           599,360
claude-haiku-4-5                        387            389,040         46,477
claude-opus-4-5                         166            1,628           67,553
claude-3-5-haiku                        10             758             1,097
──────────────────────────────────────────────────────────────────────────────────────
TOTAL                                   2,964          413,130         1,622,971

Date          Invocations    Input Tokens    Output Tokens
────────────────────────────────────────────────────────────
2026-02-05    123            415             107,347          ███
2026-02-06    188            587             94,373           █████
2026-02-07    484            2,384           593,115          ██████████████
2026-02-08    614            4,422           296,714          █████████████████
2026-02-09    379            3,542           156,475          ███████████
2026-02-10    1,059          396,154         327,829          ██████████████████████████████
2026-02-11    117            5,626           47,118           ███
```

### users — 사용자별 분석 / Per-User Analysis

CloudTrail에서 사용자별 호출 횟수, 주 사용 모델, 클라이언트(claude-code, nodejs-sdk 등)를 분석합니다.
Analyzes per-user invocations, top model, and client (claude-code, nodejs-sdk, etc.) from CloudTrail.

```bash
./bedrock-usage.sh users
./bedrock-usage.sh users --days 30
```

```
=== Bedrock Usage by User (2026-02-05 ~ 2026-02-12) ===

User                    Invocations   Top Model               Client
──────────────────────────────────────────────────────────────────────────────
alice                   1,449         claude-sonnet-4-5       nodejs-sdk
bob                     1,022         claude-haiku-4-5        claude-code
charlie                   516         claude-opus-4-6         claude-code
──────────────────────────────────────────────────────────────────────────────
TOTAL                   2,987
```

> CloudTrail은 최근 90일까지만 조회할 수 있습니다. `--days 90` 초과 시 자동으로 90일로 제한됩니다.
>
> CloudTrail only supports the last 90 days. Values exceeding 90 are automatically capped.

### cost — 비용 분석 / Cost Analysis

```bash
./bedrock-usage.sh cost
./bedrock-usage.sh cost --days 30
```

```
=== Bedrock Cost Report (2026-02-05 ~ 2026-02-12) ===

Date          Total Cost    Breakdown
──────────────────────────────────────────────────────────
2026-02-05    $1.23         Claude-Opus: $0.89, Claude-Haiku: $0.34
2026-02-06    $2.45         Claude-Opus: $1.80, Claude-Sonnet: $0.65
...
──────────────────────────────────────────────────────────
TOTAL         $12.34
```

> Cost Explorer API는 항상 `us-east-1`에서 호출됩니다. `--region` 옵션은 비용 조회에 영향을 주지 않습니다.
>
> Cost Explorer API always uses `us-east-1`. The `--region` option does not affect cost queries.

---

## 출력 형식 / Output Formats

모든 서브커맨드는 3가지 출력 형식을 지원합니다.
All subcommands support three output formats.

```bash
# 사람이 읽기 좋은 테이블 (기본) / Human-readable table (default)
./bedrock-usage.sh overview

# 프로그래밍 처리용 JSON / JSON for programmatic use
./bedrock-usage.sh -o json overview

# 스프레드시트 등으로 가져올 수 있는 CSV / CSV for spreadsheets
./bedrock-usage.sh -o csv overview > overview.csv
```

---

## 프로젝트 구조 / Project Structure

```
bedrock-usage/
├── bedrock-usage.sh      # 메인 진입점 (서브커맨드 라우팅, 옵션 파싱)
│                         # Main entry point (subcommand routing, option parsing)
├── lib/
│   ├── common.sh         # 공용 유틸리티 (날짜 계산, 포매팅, 색상, 테이블 출력)
│   │                     # Shared utilities (date calc, formatting, colors, table output)
│   ├── metrics.sh        # CloudWatch 메트릭 조회 (overview)
│   │                     # CloudWatch metric queries (overview)
│   ├── cloudtrail.sh     # CloudTrail 사용자별 분석 (users)
│   │                     # CloudTrail per-user analysis (users)
│   └── cost.sh           # Cost Explorer 비용 조회 (cost)
│                         # Cost Explorer queries (cost)
```

---

## 필요 IAM 권한 / Required IAM Permissions

도구를 사용하려면 다음 IAM 권한이 필요합니다.
The following IAM permissions are required.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "cloudwatch:ListMetrics",
        "cloudwatch:GetMetricStatistics",
        "cloudtrail:LookupEvents",
        "ce:GetCostAndUsage",
        "sts:GetCallerIdentity"
      ],
      "Resource": "*"
    }
  ]
}
```

---

## 참고사항 / Notes

- macOS (BSD date)와 Linux (GNU date) 모두 지원합니다.
  Supports both macOS (BSD date) and Linux (GNU date).

- macOS 기본 bash (3.x)와 호환됩니다. 연관 배열(associative array)을 사용하지 않습니다.
  Compatible with macOS default bash (3.x). No associative arrays used.

- 큰 숫자 연산은 `awk`를 사용하여 bash 정수 오버플로를 방지합니다.
  Large number arithmetic uses `awk` to avoid bash integer overflow.

- 터미널 연결 시 색상 출력이 활성화되며, 파이프/리다이렉트 시 자동으로 비활성화됩니다.
  Color output is enabled in terminal, automatically disabled when piped or redirected.

- CloudWatch 메트릭은 `ModelId` 차원만 지원하므로, 사용자별 분석은 CloudTrail을 통해 수행됩니다.
  CloudWatch metrics only support the `ModelId` dimension, so per-user analysis uses CloudTrail.

---

## 라이선스 / License

MIT
