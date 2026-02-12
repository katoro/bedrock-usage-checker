#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Bedrock Usage CLI - CloudWatch Metrics (lib/metrics.sh)
# ---------------------------------------------------------------------------
# Provides CloudWatch-based Bedrock usage queries: summary, per-model
# breakdown, and daily trend.
#
# Globals expected (set by bedrock-usage.sh):
#   REGION, DAYS, OUTPUT, START_DATE, END_DATE, START_DATE_SHORT, END_DATE_SHORT
#
# Depends on lib/common.sh for:
#   format_number, print_bar, print_separator, print_table_header,
#   print_table_row, to_json, to_csv, log_error, log_info, short_model_name,
#   color constants (BOLD, RESET, CYAN, etc.)
#
# Compatible with bash 3.x (macOS default). No associative arrays.
# ---------------------------------------------------------------------------

# Cache variable for the model list (populated on first call)
_METRICS_MODEL_LIST_CACHE=""

# ---------------------------------------------------------------------------
# get_model_list()
# Returns unique ModelId dimension values from CloudWatch, one per line.
# Caches the result to avoid repeated API calls.
# ---------------------------------------------------------------------------
get_model_list() {
    if [ -n "$_METRICS_MODEL_LIST_CACHE" ]; then
        printf '%s\n' "$_METRICS_MODEL_LIST_CACHE"
        return
    fi

    local raw
    raw="$(aws cloudwatch list-metrics \
        --namespace AWS/Bedrock \
        --metric-name Invocations \
        --region "$REGION" \
        --output json 2>/dev/null)" || {
        log_error "Failed to list CloudWatch metrics"
        return 1
    }

    _METRICS_MODEL_LIST_CACHE="$(printf '%s' "$raw" \
        | jq -r '.Metrics[].Dimensions[] | select(.Name == "ModelId") | .Value' \
        | sort -u)"

    if [ -z "$_METRICS_MODEL_LIST_CACHE" ]; then
        log_error "No Bedrock models found in CloudWatch metrics for region $REGION"
        return 1
    fi

    printf '%s\n' "$_METRICS_MODEL_LIST_CACHE"
}

# ---------------------------------------------------------------------------
# get_metric_sum(model_id, metric_name)
# Returns the Sum of a single metric for one model over the entire date range.
# Outputs a plain number (0 when no datapoints exist).
# ---------------------------------------------------------------------------
get_metric_sum() {
    local model_id="$1"
    local metric_name="$2"

    local period
    period=$((DAYS * 86400))

    local raw
    raw="$(aws cloudwatch get-metric-statistics \
        --namespace AWS/Bedrock \
        --metric-name "$metric_name" \
        --dimensions Name=ModelId,Value="$model_id" \
        --start-time "$START_DATE" \
        --end-time "$END_DATE" \
        --period "$period" \
        --statistics Sum \
        --region "$REGION" \
        --output json 2>/dev/null)" || {
        printf '0'
        return
    }

    local sum
    sum="$(printf '%s' "$raw" \
        | jq -r 'if (.Datapoints | length) > 0 then
                     [.Datapoints[].Sum] | add | tostring
                  else "0" end')"

    # Strip any trailing decimal zeros for clean integer display
    case "$sum" in
        *.0|*.00) sum="${sum%%.*}" ;;
    esac

    printf '%s' "${sum:-0}"
}

# ---------------------------------------------------------------------------
# get_metric_daily(metric_name)
# Returns a JSON array of {date, value} objects with daily totals across
# ALL models combined, sorted by date. Days with no data appear as 0.
# ---------------------------------------------------------------------------
get_metric_daily() {
    local metric_name="$1"

    local tmpfile
    tmpfile="$(mktemp)"
    # Ensure cleanup
    trap "rm -f '$tmpfile'" RETURN

    # Collect daily datapoints for each model into a single JSON stream
    printf '[' > "$tmpfile"
    local first_model=1

    local models
    models="$(get_model_list)" || { printf '[]\n'; return; }

    local model
    while IFS= read -r model; do
        [ -z "$model" ] && continue

        local raw
        raw="$(aws cloudwatch get-metric-statistics \
            --namespace AWS/Bedrock \
            --metric-name "$metric_name" \
            --dimensions Name=ModelId,Value="$model" \
            --start-time "$START_DATE" \
            --end-time "$END_DATE" \
            --period 86400 \
            --statistics Sum \
            --region "$REGION" \
            --output json 2>/dev/null)" || continue

        # Extract datapoints as {date, value} and append
        local points
        points="$(printf '%s' "$raw" \
            | jq -c '[.Datapoints[] | {date: (.Timestamp[:10]), value: .Sum}]')"

        # Skip empty arrays
        if [ "$points" = "[]" ] || [ -z "$points" ]; then
            continue
        fi

        # Flatten array elements into comma-separated JSON objects and append
        local flat
        flat="$(printf '%s' "$points" | jq -c '.[]' | paste -sd ',' -)"
        if [ -n "$flat" ]; then
            if [ "$first_model" -eq 1 ]; then
                first_model=0
            else
                printf ',' >> "$tmpfile"
            fi
            printf '%s' "$flat" >> "$tmpfile"
        fi
    done <<EOF
$models
EOF

    printf ']' >> "$tmpfile"

    # Generate the complete date range
    local dates_json
    dates_json="$(generate_date_range_json)"

    # Group by date, sum values, and left-join with the date range
    local raw_data
    raw_data="$(jq -c '
        group_by(.date)
        | map({date: .[0].date, value: (map(.value) | add)})
    ' "$tmpfile")"

    # Merge: for each date in range, find matching sum or default to 0
    printf '%s' "$dates_json" | jq -c --argjson data "$raw_data" '
        map(. as $d |
            ($data | map(select(.date == $d)) | if length > 0 then .[0].value else 0 end)
            | {date: $d, value: .}
        )
    '
}

# ---------------------------------------------------------------------------
# generate_date_range_json()
# Outputs a JSON array of date strings from START_DATE_SHORT to
# END_DATE_SHORT (exclusive of end), one per day.
# ---------------------------------------------------------------------------
generate_date_range_json() {
    local dates="["
    local first=1

    # Cross-platform date arithmetic using date_offset_from (from common.sh)
    local i=0
    while [ "$i" -lt "$DAYS" ]; do
        local offset=$(( i - DAYS ))
        local d
        d="$(date_offset "${offset}" '+%Y-%m-%d')"

        if [ "$first" -eq 1 ]; then
            first=0
        else
            dates="${dates},"
        fi
        dates="${dates}\"${d}\""
        i=$((i + 1))
    done

    dates="${dates}]"
    printf '%s' "$dates"
}

# ===========================================================================
# Subcommand: summary
# ===========================================================================
cmd_summary() {
    log_info "Fetching summary..."

    local models
    models="$(get_model_list)" || {
        log_error "Could not retrieve model list"
        return 1
    }

    local total_invocations=0
    local total_input_tokens=0
    local total_output_tokens=0
    local active_models=0

    local model
    while IFS= read -r model; do
        [ -z "$model" ] && continue

        local inv inp out
        inv="$(get_metric_sum "$model" "Invocations")"
        inp="$(get_metric_sum "$model" "InputTokenCount")"
        out="$(get_metric_sum "$model" "OutputTokenCount")"

        # Accumulate totals (use awk for large-number arithmetic)
        total_invocations="$(printf '%s %s' "$total_invocations" "$inv" | awk '{printf "%.0f", $1 + $2}')"
        total_input_tokens="$(printf '%s %s' "$total_input_tokens" "$inp" | awk '{printf "%.0f", $1 + $2}')"
        total_output_tokens="$(printf '%s %s' "$total_output_tokens" "$out" | awk '{printf "%.0f", $1 + $2}')"

        # Count active models
        local is_active
        is_active="$(printf '%s' "$inv" | awk '{print ($1 > 0) ? "1" : "0"}')"
        if [ "$is_active" = "1" ]; then
            active_models=$((active_models + 1))
        fi
    done <<EOF
$models
EOF

    case "$OUTPUT" in
        table)
            printf '\n'
            printf '%s=== Bedrock Usage Summary (%s ~ %s) ===%s\n' \
                "$BOLD" "$START_DATE_SHORT" "$END_DATE_SHORT" "$RESET"
            printf '\n'
            printf '  Total Invocations:   %15s\n' "$(format_number "$total_invocations")"
            printf '  Total Input Tokens:  %15s\n' "$(format_number "$total_input_tokens")"
            printf '  Total Output Tokens: %15s\n' "$(format_number "$total_output_tokens")"
            printf '  Active Models:       %15s\n' "$active_models"
            printf '\n'
            ;;
        json)
            to_json \
                "period_start=${START_DATE_SHORT}" \
                "period_end=${END_DATE_SHORT}" \
                "total_invocations=${total_invocations}" \
                "total_input_tokens=${total_input_tokens}" \
                "total_output_tokens=${total_output_tokens}" \
                "active_models=${active_models}"
            ;;
        csv)
            to_csv "period_start" "period_end" "total_invocations" "total_input_tokens" "total_output_tokens" "active_models"
            to_csv "$START_DATE_SHORT" "$END_DATE_SHORT" "$total_invocations" "$total_input_tokens" "$total_output_tokens" "$active_models"
            ;;
    esac
}

# ===========================================================================
# Subcommand: models
# ===========================================================================
cmd_models() {
    log_info "Fetching model metrics..."

    local models
    models="$(get_model_list)" || {
        log_error "Could not retrieve model list"
        return 1
    }

    # Collect per-model data as a JSON array
    local tmpfile
    tmpfile="$(mktemp)"
    trap "rm -f '$tmpfile'" RETURN

    printf '[' > "$tmpfile"
    local first=1

    local model
    while IFS= read -r model; do
        [ -z "$model" ] && continue

        local inv inp out
        inv="$(get_metric_sum "$model" "Invocations")"
        inp="$(get_metric_sum "$model" "InputTokenCount")"
        out="$(get_metric_sum "$model" "OutputTokenCount")"

        if [ "$first" -eq 1 ]; then
            first=0
        else
            printf ',' >> "$tmpfile"
        fi

        local short_name
        short_name="$(short_model_name "$model")"

        printf '{"model_id":"%s","short_name":"%s","invocations":%s,"input_tokens":%s,"output_tokens":%s}' \
            "$model" "$short_name" "${inv:-0}" "${inp:-0}" "${out:-0}" >> "$tmpfile"
    done <<EOF
$models
EOF

    printf ']' >> "$tmpfile"

    # Sort by invocations descending
    local sorted
    sorted="$(jq -c 'sort_by(-.invocations)' "$tmpfile")"

    # Compute totals
    local total_inv total_inp total_out
    total_inv="$(printf '%s' "$sorted" | jq '[.[].invocations] | add // 0 | floor')"
    total_inp="$(printf '%s' "$sorted" | jq '[.[].input_tokens] | add // 0 | floor')"
    total_out="$(printf '%s' "$sorted" | jq '[.[].output_tokens] | add // 0 | floor')"

    case "$OUTPUT" in
        table)
            local col_model=40
            local col_inv=15
            local col_inp=16
            local col_out=15

            printf '\n'
            print_table_header \
                "Model:${col_model}" \
                "Invocations:${col_inv}" \
                "Input Tokens:${col_inp}" \
                "Output Tokens:${col_out}"

            local count
            count="$(printf '%s' "$sorted" | jq 'length')"
            local idx=0
            while [ "$idx" -lt "$count" ]; do
                local row
                row="$(printf '%s' "$sorted" | jq -c ".[$idx]")"

                local sname sinv sinp sout
                sname="$(printf '%s' "$row" | jq -r '.short_name')"
                sinv="$(printf '%s' "$row" | jq '.invocations | floor')"
                sinp="$(printf '%s' "$row" | jq '.input_tokens | floor')"
                sout="$(printf '%s' "$row" | jq '.output_tokens | floor')"

                print_table_row \
                    "${sname}:${col_model}" \
                    "$(format_number "$sinv"):${col_inv}" \
                    "$(format_number "$sinp"):${col_inp}" \
                    "$(format_number "$sout"):${col_out}"

                idx=$((idx + 1))
            done

            print_separator $((col_model + col_inv + col_inp + col_out))

            print_table_row \
                "${BOLD}TOTAL${RESET}:${col_model}" \
                "$(format_number "$total_inv"):${col_inv}" \
                "$(format_number "$total_inp"):${col_inp}" \
                "$(format_number "$total_out"):${col_out}"
            printf '\n'
            ;;
        json)
            printf '%s' "$sorted" | jq '
                map({
                    model_id: .model_id,
                    short_name: .short_name,
                    invocations: (.invocations | floor),
                    input_tokens: (.input_tokens | floor),
                    output_tokens: (.output_tokens | floor)
                })
            '
            ;;
        csv)
            to_csv "model_id" "short_name" "invocations" "input_tokens" "output_tokens"
            local count
            count="$(printf '%s' "$sorted" | jq 'length')"
            local idx=0
            while [ "$idx" -lt "$count" ]; do
                local row
                row="$(printf '%s' "$sorted" | jq -c ".[$idx]")"

                local mid sname sinv sinp sout
                mid="$(printf '%s' "$row" | jq -r '.model_id')"
                sname="$(printf '%s' "$row" | jq -r '.short_name')"
                sinv="$(printf '%s' "$row" | jq '.invocations | floor')"
                sinp="$(printf '%s' "$row" | jq '.input_tokens | floor')"
                sout="$(printf '%s' "$row" | jq '.output_tokens | floor')"

                to_csv "$mid" "$sname" "$sinv" "$sinp" "$sout"
                idx=$((idx + 1))
            done
            ;;
    esac
}

# ===========================================================================
# Subcommand: trend
# ===========================================================================
cmd_trend() {
    log_info "Fetching daily trend..."

    local daily_inv daily_inp daily_out
    daily_inv="$(get_metric_daily "Invocations")"
    daily_inp="$(get_metric_daily "InputTokenCount")"
    daily_out="$(get_metric_daily "OutputTokenCount")"

    # Merge the three metric arrays by date into a single array
    local merged
    merged="$(jq -n \
        --argjson inv "$daily_inv" \
        --argjson inp "$daily_inp" \
        --argjson out "$daily_out" '
        [ range($inv | length) ] | map(
            {
                date: $inv[.].date,
                invocations: ($inv[.].value // 0),
                input_tokens: ($inp[.].value // 0),
                output_tokens: ($out[.].value // 0)
            }
        )
    ')"

    # Find max invocations for bar scaling
    local max_inv
    max_inv="$(printf '%s' "$merged" | jq '[.[].invocations] | max // 0')"

    case "$OUTPUT" in
        table)
            local col_date=14
            local col_inv=15
            local col_inp=16
            local col_out=15

            printf '\n'
            print_table_header \
                "Date:${col_date}" \
                "Invocations:${col_inv}" \
                "Input Tokens:${col_inp}" \
                "Output Tokens:${col_out}"

            local count
            count="$(printf '%s' "$merged" | jq 'length')"
            local idx=0
            while [ "$idx" -lt "$count" ]; do
                local row
                row="$(printf '%s' "$merged" | jq -c ".[$idx]")"

                local d sinv sinp sout
                d="$(printf '%s' "$row" | jq -r '.date')"
                sinv="$(printf '%s' "$row" | jq '.invocations | floor')"
                sinp="$(printf '%s' "$row" | jq '.input_tokens | floor')"
                sout="$(printf '%s' "$row" | jq '.output_tokens | floor')"

                local bar
                bar="$(print_bar "$sinv" "$max_inv" 30)"

                printf '%-'"${col_date}"'s%-'"${col_inv}"'s%-'"${col_inp}"'s%-'"${col_out}"'s  %s%s%s\n' \
                    "$d" \
                    "$(format_number "$sinv")" \
                    "$(format_number "$sinp")" \
                    "$(format_number "$sout")" \
                    "$GREEN" "$bar" "$RESET"

                idx=$((idx + 1))
            done
            printf '\n'
            ;;
        json)
            printf '%s' "$merged" | jq '
                map({
                    date: .date,
                    invocations: (.invocations | floor),
                    input_tokens: (.input_tokens | floor),
                    output_tokens: (.output_tokens | floor)
                })
            '
            ;;
        csv)
            to_csv "date" "invocations" "input_tokens" "output_tokens"
            local count
            count="$(printf '%s' "$merged" | jq 'length')"
            local idx=0
            while [ "$idx" -lt "$count" ]; do
                local row
                row="$(printf '%s' "$merged" | jq -c ".[$idx]")"

                local d sinv sinp sout
                d="$(printf '%s' "$row" | jq -r '.date')"
                sinv="$(printf '%s' "$row" | jq '.invocations | floor')"
                sinp="$(printf '%s' "$row" | jq '.input_tokens | floor')"
                sout="$(printf '%s' "$row" | jq '.output_tokens | floor')"

                to_csv "$d" "$sinv" "$sinp" "$sout"
                idx=$((idx + 1))
            done
            ;;
    esac
}
