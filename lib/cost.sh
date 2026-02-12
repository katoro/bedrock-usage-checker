#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Bedrock Usage CLI - Cost Explorer Analysis (lib/cost.sh)
# ---------------------------------------------------------------------------
# Provides Bedrock cost analysis via AWS Cost Explorer API.
#
# Globals expected (set by bedrock-usage.sh):
#   REGION, DAYS, OUTPUT, START_DATE, END_DATE, START_DATE_SHORT, END_DATE_SHORT
#
# Depends on lib/common.sh for:
#   format_number, print_separator, print_table_header, print_table_row,
#   to_json, to_csv, log_error, log_info, short_model_name,
#   color constants (BOLD, RESET, CYAN, etc.)
#
# Compatible with bash 3.x (macOS default). No associative arrays.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# simplify_usage_type()
# Simplify USAGE_TYPE names for readability.
# E.g. "USE1-InvokeModel-Anthropic-Claude-Haiku" -> "Claude-Haiku"
#      "USE2-InvokeModel-Meta-Llama3" -> "Llama3"
#      "EUW1-InvokeModel-Amazon-Titan" -> "Titan"
# ---------------------------------------------------------------------------
simplify_usage_type() {
    local raw="${1:-}"
    if [ -z "$raw" ]; then
        printf 'unknown'
        return
    fi

    local name="$raw"

    # Strip region prefix (e.g., "USE1-", "USW2-", "EUW1-")
    name="$(printf '%s' "$name" | sed -E 's/^[A-Z]{2,4}[0-9]+-//')"

    # Strip common operation prefixes
    name="$(printf '%s' "$name" | sed -E 's/^(InvokeModel|Converse|ConverseStream|InvokeModelWithResponseStream)-//')"

    # Strip provider prefixes (Anthropic-, Amazon-, Meta-, Cohere-, AI21-, Mistral-, Stability-)
    name="$(printf '%s' "$name" | sed -E 's/^(Anthropic|Amazon|Meta|Cohere|AI21|Mistral|Stability)-//')"

    # If nothing meaningful remains, use the original
    if [ -z "$name" ] || [ "$name" = "$raw" ]; then
        # Fallback: try to extract anything after the last known prefix
        name="$raw"
    fi

    printf '%s' "$name"
}

# ===========================================================================
# Subcommand: cost
# ===========================================================================
cmd_cost() {
    log_info "Fetching cost data..."

    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" RETURN

    # Determine granularity
    local granularity="DAILY"
    if [ "$DAYS" -gt 31 ]; then
        granularity="MONTHLY"
    fi

    # Cost Explorer API is ONLY available in us-east-1
    local ce_region="us-east-1"

    # Build the filter JSON
    local filter='{"Dimensions":{"Key":"SERVICE","Values":["Amazon Bedrock"]}}'

    local raw_file="$tmpdir/ce_raw.json"
    aws ce get-cost-and-usage \
        --time-period "Start=${START_DATE_SHORT},End=${END_DATE_SHORT}" \
        --granularity "$granularity" \
        --metrics BlendedCost \
        --filter "$filter" \
        --group-by Type=DIMENSION,Key=USAGE_TYPE \
        --region "$ce_region" \
        --output json > "$raw_file" 2>/dev/null || {
        log_error "Failed to fetch Cost Explorer data. Ensure you have ce:GetCostAndUsage permissions."
        return 1
    }

    # Parse response: extract per-period breakdown
    local results_file="$tmpdir/results.json"
    jq -c '
        [.ResultsByTime[] | {
            date: .TimePeriod.Start,
            groups: [
                .Groups[] | {
                    usage_type: .Keys[0],
                    cost: (.Metrics.BlendedCost.Amount | tonumber)
                }
            ] | sort_by(-.cost),
            total: ([.Groups[].Metrics.BlendedCost.Amount | tonumber] | add // 0)
        }]
    ' "$raw_file" > "$results_file"

    # Compute grand total
    local grand_total
    grand_total="$(jq '[.[].total] | add // 0' "$results_file")"

    # Build simplified usage type names via shell function
    # Get unique usage types
    local usage_types_file="$tmpdir/usage_types.txt"
    jq -r '[.[].groups[].usage_type] | unique | .[]' "$results_file" > "$usage_types_file"

    # Build a JSON mapping of usage_type -> simplified name
    local type_map_file="$tmpdir/type_map.json"
    printf '{' > "$type_map_file"
    local first_type=1
    local utype
    while IFS= read -r utype; do
        [ -z "$utype" ] && continue
        local simplified
        simplified="$(simplify_usage_type "$utype")"
        if [ "$first_type" -eq 1 ]; then
            first_type=0
        else
            printf ',' >> "$type_map_file"
        fi
        # Use jq to safely encode the key and value
        printf '%s' "$utype" | jq -Rc --arg v "$simplified" '{($0 // "unknown"): $v}' \
            | sed 's/^{//' | sed 's/}$//' >> "$type_map_file"
    done < "$usage_types_file"
    printf '}' >> "$type_map_file"

    # Enrich results with simplified names
    local enriched_file="$tmpdir/enriched.json"
    jq -c --slurpfile tmap "$type_map_file" '
        [.[] | {
            date: .date,
            total: .total,
            groups: [.groups[] | {
                usage_type: .usage_type,
                display_name: ($tmap[0][.usage_type] // .usage_type),
                cost: .cost
            }]
        }]
    ' "$results_file" > "$enriched_file"

    # Output
    case "$OUTPUT" in
        table)
            local col_date=14
            local col_total=14
            local col_breakdown=40

            printf '\n'
            printf '%s=== Bedrock Cost Report (%s ~ %s) ===%s\n' \
                "$BOLD" "$START_DATE_SHORT" "$END_DATE_SHORT" "$RESET"
            printf '\n'
            print_table_header \
                "Date:${col_date}" \
                "Total Cost:${col_total}" \
                "Breakdown:${col_breakdown}"

            local count
            count="$(jq 'length' "$enriched_file")"
            local idx=0
            while [ "$idx" -lt "$count" ]; do
                local row
                row="$(jq -c ".[$idx]" "$enriched_file")"

                local period_date period_total
                period_date="$(printf '%s' "$row" | jq -r '.date')"
                period_total="$(printf '%s' "$row" | jq '.total')"

                # Format total cost
                local formatted_total
                formatted_total="$(printf '$%.2f' "$period_total")"

                # Build breakdown string: top 3 usage types
                local breakdown
                breakdown="$(printf '%s' "$row" | jq -r '
                    [.groups[:3][] |
                        .display_name + ": $" + (.cost * 100 | round / 100 | tostring)
                    ] | join(", ")
                ')"

                if [ -z "$breakdown" ] || [ "$breakdown" = "null" ]; then
                    breakdown="-"
                fi

                # Truncate breakdown if too long
                if [ "${#breakdown}" -gt 38 ]; then
                    breakdown="$(printf '%.35s...' "$breakdown")"
                fi

                print_table_row \
                    "${period_date}:${col_date}" \
                    "${formatted_total}:${col_total}" \
                    "${breakdown}:${col_breakdown}"

                idx=$((idx + 1))
            done

            print_separator $((col_date + col_total + col_breakdown))

            local formatted_grand
            formatted_grand="$(printf '$%.2f' "$grand_total")"

            print_table_row \
                "${BOLD}TOTAL${RESET}:${col_date}" \
                "${formatted_grand}:${col_total}" \
                ":${col_breakdown}"
            printf '\n'
            ;;
        json)
            jq '
                map({
                    date: .date,
                    total_cost: (.total * 100 | round / 100),
                    breakdown: [.groups[] | {
                        usage_type: .display_name,
                        cost: (.cost * 100 | round / 100)
                    }]
                })
            ' "$enriched_file"
            ;;
        csv)
            to_csv "date" "total_cost" "usage_type_1" "cost_1" "usage_type_2" "cost_2" "usage_type_3" "cost_3"
            local count
            count="$(jq 'length' "$enriched_file")"
            local idx=0
            while [ "$idx" -lt "$count" ]; do
                local row
                row="$(jq -c ".[$idx]" "$enriched_file")"

                local period_date period_total
                period_date="$(printf '%s' "$row" | jq -r '.date')"
                period_total="$(printf '%s' "$row" | jq '.total * 100 | round / 100')"

                # Extract top 3 usage types and their costs
                local ut1 c1 ut2 c2 ut3 c3
                ut1="$(printf '%s' "$row" | jq -r '.groups[0].display_name // ""')"
                c1="$(printf '%s' "$row" | jq '.groups[0].cost // 0 | . * 100 | round / 100')"
                ut2="$(printf '%s' "$row" | jq -r '.groups[1].display_name // ""')"
                c2="$(printf '%s' "$row" | jq '.groups[1].cost // 0 | . * 100 | round / 100')"
                ut3="$(printf '%s' "$row" | jq -r '.groups[2].display_name // ""')"
                c3="$(printf '%s' "$row" | jq '.groups[2].cost // 0 | . * 100 | round / 100')"

                to_csv "$period_date" "$period_total" "$ut1" "$c1" "$ut2" "$c2" "$ut3" "$c3"
                idx=$((idx + 1))
            done
            ;;
    esac
}
