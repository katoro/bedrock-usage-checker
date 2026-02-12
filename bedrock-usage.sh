#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Bedrock Usage CLI - Main Entry Point
# ---------------------------------------------------------------------------

# Resolve the directory where this script lives (follow symlinks)
SOURCE="${BASH_SOURCE[0]}"
while [ -L "$SOURCE" ]; do
    SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"
    SOURCE="$(readlink "$SOURCE")"
    # If SOURCE is relative, resolve it relative to the symlink directory
    [[ "$SOURCE" != /* ]] && SOURCE="$SCRIPT_DIR/$SOURCE"
done
SCRIPT_DIR="$(cd -P "$(dirname "$SOURCE")" && pwd)"

# ---------------------------------------------------------------------------
# Source library modules
# ---------------------------------------------------------------------------
source "$SCRIPT_DIR/lib/common.sh"
source "$SCRIPT_DIR/lib/metrics.sh"
source "$SCRIPT_DIR/lib/cloudtrail.sh"
source "$SCRIPT_DIR/lib/cost.sh"

# ---------------------------------------------------------------------------
# Dependency check
# ---------------------------------------------------------------------------
missing_deps=()
for cmd in aws jq bc; do
    if ! command -v "$cmd" &>/dev/null; then
        missing_deps+=("$cmd")
    fi
done

if [ ${#missing_deps[@]} -gt 0 ]; then
    printf "Error: missing required dependencies: %s\n" "${missing_deps[*]}" >&2
    printf "Please install them before running this tool.\n" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Global defaults
# ---------------------------------------------------------------------------
REGION="us-east-1"
DAYS=7
OUTPUT="table"

# ---------------------------------------------------------------------------
# Help text
# ---------------------------------------------------------------------------
show_help() {
    printf "%s" "\
Usage: bedrock-usage.sh [options] <subcommand> [subcommand-options]

Analyze AWS Bedrock usage, costs, and trends.

Subcommands:
  summary     Show overall usage summary for the period
  models      Show per-model usage breakdown
  users       Show per-user/role usage breakdown
  trend       Show daily usage trend over the period
  cost        Show cost analysis and estimates
  help        Show this help message

Common Options:
  -r, --region <region>   AWS region (default: us-east-1)
  -d, --days <days>       Number of days to look back (default: 7)
  -o, --output <format>   Output format: table, json, csv (default: table)
  -h, --help              Show this help message

Examples:
  bedrock-usage.sh summary
  bedrock-usage.sh --region us-west-2 --days 30 models
  bedrock-usage.sh -d 14 -o json trend
  bedrock-usage.sh cost --days 30
"
}

# ---------------------------------------------------------------------------
# Parse common options (before subcommand)
# ---------------------------------------------------------------------------
SUBCOMMAND=""

while [ $# -gt 0 ]; do
    case "$1" in
        -r|--region)
            if [ $# -lt 2 ]; then
                log_error "Option $1 requires a value"
                exit 1
            fi
            REGION="$2"
            shift 2
            ;;
        -d|--days)
            if [ $# -lt 2 ]; then
                log_error "Option $1 requires a value"
                exit 1
            fi
            DAYS="$2"
            # Validate that DAYS is a positive integer
            if ! printf '%s' "$DAYS" | grep -qE '^[0-9]+$' || [ "$DAYS" -le 0 ]; then
                log_error "Days must be a positive integer, got: $DAYS"
                exit 1
            fi
            shift 2
            ;;
        -o|--output)
            if [ $# -lt 2 ]; then
                log_error "Option $1 requires a value"
                exit 1
            fi
            OUTPUT="$2"
            # Validate output format
            case "$OUTPUT" in
                table|json|csv)
                    ;;
                *)
                    log_error "Invalid output format: $OUTPUT (must be table, json, or csv)"
                    exit 1
                    ;;
            esac
            shift 2
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        -*)
            log_error "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            # First non-option argument is the subcommand
            SUBCOMMAND="$1"
            shift
            break
            ;;
    esac
done

# ---------------------------------------------------------------------------
# Export globals and compute date range
# ---------------------------------------------------------------------------
export REGION
export DAYS
export OUTPUT

calc_date_range

export START_DATE
export END_DATE
export START_DATE_SHORT
export END_DATE_SHORT

# ---------------------------------------------------------------------------
# Check AWS credentials before executing any subcommand (except help)
# ---------------------------------------------------------------------------
if [ "$SUBCOMMAND" != "help" ] && [ -n "$SUBCOMMAND" ]; then
    check_aws_credentials
fi

# ---------------------------------------------------------------------------
# Dispatch to subcommand
# ---------------------------------------------------------------------------
case "${SUBCOMMAND}" in
    summary)
        cmd_summary "$@"
        ;;
    models)
        cmd_models "$@"
        ;;
    users)
        cmd_users "$@"
        ;;
    trend)
        cmd_trend "$@"
        ;;
    cost)
        cmd_cost "$@"
        ;;
    help)
        show_help
        exit 0
        ;;
    "")
        show_help
        exit 0
        ;;
    *)
        log_error "Unknown subcommand: $SUBCOMMAND"
        printf "\n" >&2
        show_help
        exit 1
        ;;
esac
