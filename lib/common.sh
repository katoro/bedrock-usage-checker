#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Bedrock Usage CLI - Shared Utilities (lib/common.sh)
# ---------------------------------------------------------------------------
# Compatible with bash 3.x (macOS default). No associative arrays used.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Color constants - use tput when stdout is a terminal, empty otherwise
# ---------------------------------------------------------------------------
if [ -t 1 ] && command -v tput &>/dev/null; then
    RED="$(tput setaf 1)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"
    CYAN="$(tput setaf 6)"
    BOLD="$(tput bold)"
    RESET="$(tput sgr0)"
else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    CYAN=""
    BOLD=""
    RESET=""
fi

# ---------------------------------------------------------------------------
# Platform detection for date command
# macOS uses BSD date (-v flag), Linux uses GNU date (-d flag)
# ---------------------------------------------------------------------------
if date -v-1d '+%Y' &>/dev/null 2>&1; then
    _DATE_CMD="bsd"
else
    _DATE_CMD="gnu"
fi

# ---------------------------------------------------------------------------
# date_offset()
# Cross-platform date arithmetic. Returns a formatted date offset from today.
# Args: offset_days (negative = past), format (e.g. '+%Y-%m-%d')
# Example: date_offset -7 '+%Y-%m-%dT00:00:00Z'
# ---------------------------------------------------------------------------
date_offset() {
    local offset_days="$1"
    local fmt="$2"

    if [ "$_DATE_CMD" = "bsd" ]; then
        date -u -v"${offset_days}"d "$fmt"
    else
        date -u -d "${offset_days} days" "$fmt"
    fi
}

# ---------------------------------------------------------------------------
# date_offset_from()
# Cross-platform date arithmetic from a base date string (YYYY-MM-DD).
# Args: base_date, offset_days, format
# Example: date_offset_from "2026-02-05" +3 '+%Y-%m-%d'
# ---------------------------------------------------------------------------
date_offset_from() {
    local base="$1"
    local offset_days="$2"
    local fmt="$3"

    if [ "$_DATE_CMD" = "bsd" ]; then
        date -u -j -f '%Y-%m-%d' "$base" -v"${offset_days}"d "$fmt"
    else
        date -u -d "${base} ${offset_days} days" "$fmt"
    fi
}

# ---------------------------------------------------------------------------
# calc_date_range()
# Given global DAYS, compute START_DATE and END_DATE in ISO8601 format.
# Sets: START_DATE, END_DATE, START_DATE_SHORT, END_DATE_SHORT
# Works on both macOS (BSD date) and Linux (GNU date).
# ---------------------------------------------------------------------------
calc_date_range() {
    if [ -z "${DAYS:-}" ]; then
        log_error "calc_date_range: DAYS is not set"
        return 1
    fi

    END_DATE="$(date -u '+%Y-%m-%dT00:00:00Z')"
    END_DATE_SHORT="$(date -u '+%Y-%m-%d')"

    START_DATE="$(date_offset "-${DAYS}" '+%Y-%m-%dT00:00:00Z')"
    START_DATE_SHORT="$(date_offset "-${DAYS}" '+%Y-%m-%d')"
}

# ---------------------------------------------------------------------------
# format_number()
# Takes a number, outputs with comma thousands separator.
# Handles integers and decimals. E.g. 1234567 -> 1,234,567
# ---------------------------------------------------------------------------
format_number() {
    local num="${1:-0}"

    # Split into integer and decimal parts
    local int_part dec_part
    case "$num" in
        *.*)
            int_part="${num%%.*}"
            dec_part="${num#*.}"
            ;;
        *)
            int_part="$num"
            dec_part=""
            ;;
    esac

    # Handle negative numbers
    local sign=""
    case "$int_part" in
        -*)
            sign="-"
            int_part="${int_part#-}"
            ;;
    esac

    # Add commas to integer part using awk for bash 3.x compatibility
    local formatted
    formatted="$(printf '%s' "$int_part" | awk '{
        n = length($0)
        result = ""
        for (i = 1; i <= n; i++) {
            if (i > 1 && (n - i + 1) % 3 == 0) {
                result = result ","
            }
            result = result substr($0, i, 1)
        }
        print result
    }')"

    if [ -n "$dec_part" ]; then
        printf '%s%s.%s' "$sign" "$formatted" "$dec_part"
    else
        printf '%s%s' "$sign" "$formatted"
    fi
}

# ---------------------------------------------------------------------------
# print_bar()
# Prints a horizontal bar using block characters.
# Args: current_value, max_value, [max_width=30]
# ---------------------------------------------------------------------------
print_bar() {
    local current="${1:-0}"
    local max="${2:-0}"
    local max_width="${3:-30}"

    if [ -z "$current" ] || [ -z "$max" ]; then
        return
    fi

    # If max is 0, print empty bar
    local is_zero
    is_zero="$(printf '%s' "$max" | awk '{print ($1 == 0) ? "1" : "0"}')"
    if [ "$is_zero" = "1" ]; then
        printf ''
        return
    fi

    # Calculate bar length
    local bar_len
    bar_len="$(printf '%s %s %s' "$current" "$max" "$max_width" | awk '{
        if ($2 == 0) { print 0 }
        else {
            len = int(($1 / $2) * $3 + 0.5)
            if (len > $3) len = $3
            if (len < 0) len = 0
            print len
        }
    }')"

    local i=0
    while [ "$i" -lt "$bar_len" ]; do
        printf '\xe2\x96\x88'
        i=$((i + 1))
    done
}

# ---------------------------------------------------------------------------
# print_separator()
# Prints a line of horizontal box-drawing characters.
# Args: [width=80]
# ---------------------------------------------------------------------------
print_separator() {
    local width="${1:-80}"
    local i=0
    while [ "$i" -lt "$width" ]; do
        printf '\xe2\x94\x80'
        i=$((i + 1))
    done
    printf '\n'
}

# ---------------------------------------------------------------------------
# print_table_header()
# Takes column specs as arguments, each in "name:width" format.
# Prints the header row with proper spacing, then a separator line.
# Example: print_table_header "Model:30" "Requests:12" "Tokens:15"
# ---------------------------------------------------------------------------
print_table_header() {
    if [ $# -eq 0 ]; then
        return
    fi

    local total_width=0
    local header_line=""

    # Build header line
    for spec in "$@"; do
        local col_name="${spec%%:*}"
        local col_width="${spec##*:}"

        # Validate width is numeric, default to 10
        case "$col_width" in
            ''|*[!0-9]*) col_width=10 ;;
        esac

        header_line="${header_line}$(printf "${BOLD}%-${col_width}s${RESET}" "$col_name")"
        total_width=$((total_width + col_width))
    done

    printf '%s\n' "$header_line"
    print_separator "$total_width"
}

# ---------------------------------------------------------------------------
# print_table_row()
# Takes values to print, aligned to previously defined column widths.
# The column widths must be passed as "value:width" pairs, matching the
# header spec order.
# Example: print_table_row "claude-sonnet:30" "1234:12" "56789:15"
# ---------------------------------------------------------------------------
print_table_row() {
    if [ $# -eq 0 ]; then
        return
    fi

    local row_line=""

    for spec in "$@"; do
        local col_value="${spec%%:*}"
        local col_width="${spec##*:}"

        # Validate width is numeric, default to 10
        case "$col_width" in
            ''|*[!0-9]*) col_width=10 ;;
        esac

        row_line="${row_line}$(printf "%-${col_width}s" "$col_value")"
    done

    printf '%s\n' "$row_line"
}

# ---------------------------------------------------------------------------
# to_json()
# Converts key=value pairs into a JSON object using jq.
# Args: key1=value1 key2=value2 ...
# Values that look numeric stay as numbers; everything else is a string.
# No eval is used — builds a JSON object safely via jq piping.
# ---------------------------------------------------------------------------
to_json() {
    if [ $# -eq 0 ]; then
        printf '{}\n'
        return
    fi

    # Build a JSON object incrementally using jq, starting from {}
    local result="{}"

    for pair in "$@"; do
        local key="${pair%%=*}"
        local value="${pair#*=}"

        # Check if value is numeric (integer or float)
        local is_num
        is_num="$(printf '%s' "$value" | awk '{
            if ($0 ~ /^-?[0-9]+\.?[0-9]*$/) print "1"
            else print "0"
        }')"

        if [ "$is_num" = "1" ]; then
            result="$(printf '%s' "$result" | jq -c --arg k "$key" --argjson v "$value" '. + {($k): $v}')"
        else
            result="$(printf '%s' "$result" | jq -c --arg k "$key" --arg v "$value" '. + {($k): $v}')"
        fi
    done

    printf '%s\n' "$result" | jq .
}

# ---------------------------------------------------------------------------
# to_csv()
# Outputs arguments as a single CSV row. Values containing commas, quotes,
# or newlines are properly escaped.
# ---------------------------------------------------------------------------
to_csv() {
    local first=1
    for val in "$@"; do
        if [ "$first" -eq 1 ]; then
            first=0
        else
            printf ','
        fi

        # If value contains comma, double-quote, or newline, quote it
        case "$val" in
            *,*|*\"*|*$'\n'*)
                # Escape double quotes by doubling them
                local escaped
                escaped="$(printf '%s' "$val" | sed 's/"/""/g')"
                printf '"%s"' "$escaped"
                ;;
            *)
                printf '%s' "$val"
                ;;
        esac
    done
    printf '\n'
}

# ---------------------------------------------------------------------------
# check_aws_credentials()
# Verify that AWS credentials are configured. Exits with a helpful message
# if the caller identity cannot be resolved.
# ---------------------------------------------------------------------------
check_aws_credentials() {
    if ! aws sts get-caller-identity --region "${REGION:-us-east-1}" &>/dev/null; then
        log_error "AWS credentials are not configured or have expired."
        printf >&2 '%s\n' \
            "" \
            "Please configure credentials using one of:" \
            "  - aws configure" \
            "  - export AWS_PROFILE=<profile-name>" \
            "  - export AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY" \
            "  - aws sso login" \
            ""
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# log_error()
# Print an error message to stderr in red.
# ---------------------------------------------------------------------------
log_error() {
    local msg="${1:-}"
    if [ -z "$msg" ]; then
        return
    fi
    printf '%sError: %s%s\n' "$RED" "$msg" "$RESET" >&2
}

# ---------------------------------------------------------------------------
# log_info()
# Print an informational message to stderr in blue.
# Only prints when OUTPUT is "table" (to avoid polluting json/csv output).
# ---------------------------------------------------------------------------
log_info() {
    local msg="${1:-}"
    if [ -z "$msg" ]; then
        return
    fi
    if [ "${OUTPUT:-table}" = "table" ]; then
        printf '%s%s%s\n' "$BLUE" "$msg" "$RESET" >&2
    fi
}

# ---------------------------------------------------------------------------
# short_model_name()
# Extract a human-readable short model name from a full ARN or model ID.
#
# Examples:
#   "arn:aws:bedrock:us-east-1::foundation-model/anthropic.claude-sonnet-4-5-20250514-v1:0"
#       -> "claude-sonnet-4-5"
#   "anthropic.claude-3-haiku-20240307-v1:0"
#       -> "claude-3-haiku"
#   "amazon.titan-text-express-v1"
#       -> "titan-text-express"
#   "meta.llama3-70b-instruct-v1:0"
#       -> "llama3-70b-instruct"
#   "anthropic.claude-v2:1"
#       -> "claude-v2"
# ---------------------------------------------------------------------------
short_model_name() {
    local full="${1:-}"
    if [ -z "$full" ]; then
        printf 'unknown'
        return
    fi

    local name="$full"

    # Step 1: Strip ARN prefix — everything up to and including the last /
    case "$name" in
        arn:*)
            name="${name##*/}"
            ;;
    esac

    # Step 2: Strip provider prefix (e.g. "anthropic.", "amazon.", "meta.", "cohere.", "ai21.", "mistral.", "stability.")
    case "$name" in
        anthropic.*|amazon.*|meta.*|cohere.*|ai21.*|mistral.*|stability.*)
            name="${name#*.}"
            ;;
    esac

    # Step 3: Strip version suffix ":0", ":1", etc.
    case "$name" in
        *:[0-9]*)
            name="${name%%:*}"
            ;;
    esac

    # Step 4: Strip date-like suffix pattern -YYYYMMDD and trailing -vN
    # E.g. "claude-sonnet-4-5-20250514-v1" -> "claude-sonnet-4-5"
    # We look for -YYYYMMDD (8 digits) optionally followed by -vN
    name="$(printf '%s' "$name" | sed -E 's/-[0-9]{8}(-v[0-9]+)?$//')"

    # Step 5: Strip standalone trailing -vN if still present (e.g. "titan-text-express-v1")
    # But only if the remaining name would still have at least two hyphen-separated
    # segments (to preserve names like "claude-v2" where -v2 is integral).
    local candidate
    candidate="$(printf '%s' "$name" | sed -E 's/-v[0-9]+$//')"
    # Count hyphens in candidate — if it still contains at least one hyphen, use it
    case "$candidate" in
        *-*)
            name="$candidate"
            ;;
    esac

    printf '%s' "$name"
}
