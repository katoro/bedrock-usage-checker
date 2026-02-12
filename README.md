# Bedrock Usage CLI

AWS Bedrock 사용량을 모델별, 사용자별, 비용별로 간편하게 조회하는 Shell Script 도구입니다.

A Shell Script tool for easily querying AWS Bedrock usage by model, user, and cost.

---

## 주요 기능 / Features

| 커맨드 / Command | 설명 / Description |
|---|---|
| `summary` | 기간 내 전체 요약 (호출 수, 토큰, 활성 모델 수) / Overall summary (invocations, tokens, active models) |
| `models` | 모델별 호출·토큰 상세 / Per-model invocation & token breakdown |
| `users` | 사용자별 호출 횟수 및 주 사용 모델 / Per-user invocation count & top model |
| `trend` | 일별 호출·토큰 추이 (바 차트 포함) / Daily invocation & token trend with bar chart |
| `cost` | 일별/월별 Bedrock 비용 분석 / Daily/monthly cost breakdown |

### 데이터 소스 / Data Sources

- **summary, models, trend** — CloudWatch Metrics (`AWS/Bedrock` 네임스페이스)
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

### summary — 전체 요약 / Overall Summary

```bash
./bedrock-usage.sh summary
./bedrock-usage.sh summary --days 30
```

```
=== Bedrock Usage Summary (2026-02-05 ~ 2026-02-12) ===

  Total Invocations:             2,964
  Total Input Tokens:          413,130
  Total Output Tokens:       1,622,971
  Active Models:                     6
```

### models — 모델별 상세 / Per-Model Breakdown

```bash
./bedrock-usage.sh models
./bedrock-usage.sh models --days 14
```

```
Model                                   Invocations    Input Tokens    Output Tokens
────────────────────────────────────────────────────────────────────────────────────────
claude-opus-4-6                             1,234         234,567          890,123
claude-sonnet-4-5                             890         123,456          456,789
claude-haiku-4-5                              540          45,678          198,765
────────────────────────────────────────────────────────────────────────────────────────
TOTAL                                       2,964         413,130        1,622,971
```

### users — 사용자별 분석 / Per-User Analysis

```bash
./bedrock-usage.sh users
./bedrock-usage.sh users --days 30
```

```
=== Bedrock Usage by User (2026-02-05 ~ 2026-02-12) ===

User                    Invocations   Top Model
──────────────────────────────────────────────────────────
sshyun                      2,100     claude-opus-4-6
admin                         864     claude-sonnet-4-5
──────────────────────────────────────────────────────────
TOTAL                       2,964
```

> CloudTrail은 최근 90일까지만 조회할 수 있습니다. `--days 90` 초과 시 자동으로 90일로 제한됩니다.
>
> CloudTrail only supports the last 90 days. Values exceeding 90 are automatically capped.

### trend — 일별 추이 / Daily Trend

```bash
./bedrock-usage.sh trend
./bedrock-usage.sh trend --days 14
```

```
Date          Invocations    Input Tokens    Output Tokens
─────────────────────────────────────────────────────────────
2026-02-05    312            45,678          178,901   ████████████
2026-02-06    523            67,890          267,890   ████████████████████
2026-02-07    489            62,345          245,678   ██████████████████
...
```

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
./bedrock-usage.sh summary

# 프로그래밍 처리용 JSON / JSON for programmatic use
./bedrock-usage.sh -o json summary

# 스프레드시트 등으로 가져올 수 있는 CSV / CSV for spreadsheets
./bedrock-usage.sh -o csv models > models.csv
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
│   ├── metrics.sh        # CloudWatch 메트릭 조회 (summary, models, trend)
│   │                     # CloudWatch metric queries (summary, models, trend)
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
