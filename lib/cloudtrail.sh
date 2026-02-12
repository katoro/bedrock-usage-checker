#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# Bedrock Usage CLI - CloudTrail User Analysis (lib/cloudtrail.sh)
# ---------------------------------------------------------------------------
# Provides per-user Bedrock invocation analysis via CloudTrail events.
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
# short_client_name()
# Extract a human-readable client name from a CloudTrail userAgent string.
#
# Examples:
#   "claude-cli/2.1.38 (external, cli)"                  -> "claude-code"
#   "aws-sdk-js/3.986.0 ... nodejs#22.22.0 ..."          -> "nodejs-sdk"
#   "Boto3/1.34.0 Python/3.12.0 ..."                     -> "python-sdk"
#   "aws-cli/2.15.0 Python/3.11.0 ..."                   -> "aws-cli"
#   "aws-sdk-java/2.20.0 ..."                             -> "java-sdk"
#   "aws-sdk-go-v2/1.25.0 ..."                            -> "go-sdk"
#   "APN/1.0 Anthropic/Bedrock ..."                       -> "anthropic-api"
#   ""                                                     -> "unknown"
# ---------------------------------------------------------------------------
short_client_name() {
    local ua="${1:-}"
    if [ -z "$ua" ]; then
        printf 'unknown'
        return
    fi

    case "$ua" in
        claude-cli*|claude-code*)
            printf 'claude-code'
            ;;
        *Boto3*|*botocore*)
            printf 'python-sdk'
            ;;
        aws-cli*)
            printf 'aws-cli'
            ;;
        aws-sdk-js*)
            printf 'nodejs-sdk'
            ;;
        aws-sdk-java*)
            printf 'java-sdk'
            ;;
        aws-sdk-go*)
            printf 'go-sdk'
            ;;
        aws-sdk-ruby*)
            printf 'ruby-sdk'
            ;;
        aws-sdk-dotnet*|aws-sdk-net*)
            printf 'dotnet-sdk'
            ;;
        *Anthropic*|APN/*)
            printf 'anthropic-api'
            ;;
        *)
            # Extract the first token before / as a fallback
            local first_token
            first_token="$(printf '%s' "$ua" | sed 's|/.*||')"
            if [ -n "$first_token" ] && [ "${#first_token}" -le 20 ]; then
                printf '%s' "$first_token"
            else
                printf 'other'
            fi
            ;;
    esac
}

# ===========================================================================
# Subcommand: users
# ===========================================================================
cmd_users() {
    local effective_days="$DAYS"
    local effective_start="$START_DATE"

    # CloudTrail lookup-events only supports last 90 days
    if [ "$effective_days" -gt 90 ]; then
        log_info "Warning: CloudTrail only supports the last 90 days. Capping at 90."
        effective_days=90
        effective_start="$(date_offset -90 '+%Y-%m-%dT00:00:00Z')"
    fi

    log_info "Fetching CloudTrail events..."

    local tmpdir
    tmpdir="$(mktemp -d)"
    trap "rm -rf '$tmpdir'" RETURN

    local all_events="$tmpdir/all_events.json"
    printf '[\n' > "$all_events"
    local first_event=1

    # CloudTrail lookup-events supports only one AttributeValue at a time,
    # so we query each event name separately and merge results.
    local event_name
    for event_name in InvokeModel InvokeModelWithResponseStream ConverseStream; do
        local next_token=""
        local page_num=0

        while true; do
            local page_file="$tmpdir/page_${event_name}_${page_num}.json"

            # Build arguments as an array to avoid eval
            local ct_args=()
            ct_args+=(--lookup-attributes "AttributeKey=EventName,AttributeValue=$event_name")
            ct_args+=(--start-time "$effective_start" --end-time "$END_DATE")
            ct_args+=(--region "$REGION" --output json --max-results 50)

            if [ -n "$next_token" ]; then
                ct_args+=(--next-token "$next_token")
            fi

            local raw
            raw="$(aws cloudtrail lookup-events "${ct_args[@]}" 2>/dev/null)" || {
                log_error "Failed to query CloudTrail for $event_name events"
                break
            }

            printf '%s' "$raw" > "$page_file"

            # Extract events from this page and append to all_events
            local event_count
            event_count="$(printf '%s' "$raw" | jq '.Events | length')"

            if [ "$event_count" -gt 0 ]; then
                local idx=0
                while [ "$idx" -lt "$event_count" ]; do
                    if [ "$first_event" -eq 1 ]; then
                        first_event=0
                    else
                        printf ',\n' >> "$all_events"
                    fi
                    printf '%s' "$raw" | jq -c ".Events[$idx]" >> "$all_events"
                    idx=$((idx + 1))
                done
            fi

            # Check for pagination
            next_token="$(printf '%s' "$raw" | jq -r '.NextToken // empty')"
            if [ -z "$next_token" ]; then
                break
            fi

            page_num=$((page_num + 1))
        done
    done

    printf '\n]' >> "$all_events"

    # Verify we have events
    local total_events
    total_events="$(jq 'length' "$all_events")"

    if [ "$total_events" -eq 0 ]; then
        log_info "No Bedrock invocation events found in the specified period."
        case "$OUTPUT" in
            table)
                printf '\n%s=== Bedrock Usage by User (%s ~ %s) ===%s\n\n' \
                    "$BOLD" "$START_DATE_SHORT" "$END_DATE_SHORT" "$RESET"
                printf '  No events found.\n\n'
                ;;
            json)
                printf '[]\n'
                ;;
            csv)
                to_csv "user" "invocations" "top_model" "top_client"
                ;;
        esac
        return 0
    fi

    # Parse each event: extract username, modelId, and userAgent
    # CloudTrailEvent is a JSON string that needs to be parsed with fromjson
    local parsed_file="$tmpdir/parsed.json"
    jq -c '
        [ .[] |
            (.CloudTrailEvent | fromjson) as $ct |
            {
                user: (
                    $ct.userIdentity.userName //
                    $ct.userIdentity.sessionContext.sessionIssuer.userName //
                    (
                        $ct.userIdentity.arn |
                        if . then
                            split("/") | last
                        else
                            "unknown"
                        end
                    ) //
                    "unknown"
                ),
                model: (
                    $ct.requestParameters.modelId // "unknown"
                ),
                user_agent: (
                    $ct.userAgent // "unknown"
                )
            }
        ]
    ' "$all_events" > "$parsed_file"

    # Build model name mapping
    local models_file="$tmpdir/models.txt"
    jq -r '[.[].model] | unique | .[]' "$parsed_file" > "$models_file"

    local model_map_file="$tmpdir/model_map.json"
    printf '{' > "$model_map_file"
    local first_map=1
    local raw_model
    while IFS= read -r raw_model; do
        [ -z "$raw_model" ] && continue
        local sname
        sname="$(short_model_name "$raw_model")"
        if [ "$first_map" -eq 1 ]; then
            first_map=0
        else
            printf ',' >> "$model_map_file"
        fi
        printf '"%s":"%s"' "$raw_model" "$sname" >> "$model_map_file"
    done < "$models_file"
    printf '}' >> "$model_map_file"

    # Build client name mapping from unique userAgent strings
    local agents_file="$tmpdir/agents.txt"
    jq -r '[.[].user_agent] | unique | .[]' "$parsed_file" > "$agents_file"

    local client_map_file="$tmpdir/client_map.json"
    printf '{' > "$client_map_file"
    local first_client=1
    local raw_agent
    while IFS= read -r raw_agent; do
        [ -z "$raw_agent" ] && continue
        local cname
        cname="$(short_client_name "$raw_agent")"
        if [ "$first_client" -eq 1 ]; then
            first_client=0
        else
            printf ',' >> "$client_map_file"
        fi
        # Use jq to safely encode the key (userAgent can contain special chars)
        printf '%s' "$raw_agent" | jq -Rc --arg v "$cname" '. as $k | {($k): $v}' \
            | sed 's/^{//' | sed 's/}$//' >> "$client_map_file"
    done < "$agents_file"
    printf '}' >> "$client_map_file"

    # Aggregate: per user -> total count, top model, top client
    local aggregated_file="$tmpdir/aggregated.json"
    jq -c --slurpfile mmap "$model_map_file" --slurpfile cmap "$client_map_file" '
        group_by(.user) |
        map({
            user: .[0].user,
            invocations: length,
            models: (
                group_by(.model) |
                map({
                    model: .[0].model,
                    short_name: ($mmap[0][.[0].model] // .[0].model),
                    count: length
                }) |
                sort_by(-.count)
            ),
            clients: (
                group_by(.user_agent) |
                map({
                    user_agent: .[0].user_agent,
                    client: ($cmap[0][.[0].user_agent] // "unknown"),
                    count: length
                }) |
                sort_by(-.count)
            )
        }) |
        map(. + {
            top_model: .models[0].short_name,
            top_client: .clients[0].client
        }) |
        sort_by(-.invocations)
    ' "$parsed_file" > "$aggregated_file"

    # Compute grand total
    local grand_total
    grand_total="$(jq '[.[].invocations] | add // 0' "$aggregated_file")"

    # Output
    case "$OUTPUT" in
        table)
            local col_user=24
            local col_inv=14
            local col_top=24
            local col_client=16

            printf '\n'
            printf '%s=== Bedrock Usage by User (%s ~ %s) ===%s\n' \
                "$BOLD" "$START_DATE_SHORT" "$END_DATE_SHORT" "$RESET"
            printf '\n'
            print_table_header \
                "User:${col_user}" \
                "Invocations:${col_inv}" \
                "Top Model:${col_top}" \
                "Client:${col_client}"

            local count
            count="$(jq 'length' "$aggregated_file")"
            local idx=0
            while [ "$idx" -lt "$count" ]; do
                local row
                row="$(jq -c ".[$idx]" "$aggregated_file")"

                local uname uinv utop uclient
                uname="$(printf '%s' "$row" | jq -r '.user')"
                uinv="$(printf '%s' "$row" | jq '.invocations')"
                utop="$(printf '%s' "$row" | jq -r '.top_model')"
                uclient="$(printf '%s' "$row" | jq -r '.top_client')"

                print_table_row \
                    "${uname}:${col_user}" \
                    "$(format_number "$uinv"):${col_inv}" \
                    "${utop}:${col_top}" \
                    "${uclient}:${col_client}"

                idx=$((idx + 1))
            done

            print_separator $((col_user + col_inv + col_top + col_client))

            print_table_row \
                "${BOLD}TOTAL${RESET}:${col_user}" \
                "$(format_number "$grand_total"):${col_inv}" \
                ":${col_top}" \
                ":${col_client}"
            printf '\n'
            ;;
        json)
            jq '
                map({
                    user: .user,
                    invocations: .invocations,
                    top_model: .top_model,
                    top_client: .top_client,
                    models: [.models[] | {model: .short_name, count: .count}],
                    clients: [.clients[] | {client: .client, count: .count}]
                })
            ' "$aggregated_file"
            ;;
        csv)
            to_csv "user" "invocations" "top_model" "top_client"
            local count
            count="$(jq 'length' "$aggregated_file")"
            local idx=0
            while [ "$idx" -lt "$count" ]; do
                local row
                row="$(jq -c ".[$idx]" "$aggregated_file")"

                local uname uinv utop uclient
                uname="$(printf '%s' "$row" | jq -r '.user')"
                uinv="$(printf '%s' "$row" | jq '.invocations')"
                utop="$(printf '%s' "$row" | jq -r '.top_model')"
                uclient="$(printf '%s' "$row" | jq -r '.top_client')"

                to_csv "$uname" "$uinv" "$utop" "$uclient"
                idx=$((idx + 1))
            done
            ;;
    esac
}
