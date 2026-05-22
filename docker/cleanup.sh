#!/bin/bash
# cleanup.sh — CSV-driven file cleanup engine
# Reads CLEANUP_RULES env var. Format per rule: name:dirs:patterns:hours:enabled
# Multi-value separator within dirs/patterns: |   Rule separator: ,

source /utils.sh

_stat_size() {
    local f="$1"
    if [[ "$(uname -s)" == "Darwin" ]]; then
        stat -f %z "$f" 2>/dev/null || echo 0
    else
        stat -c %s "$f" 2>/dev/null || echo 0
    fi
}

_format_size() {
    local size="$1"
    [[ "$size" =~ ^[0-9]+$ ]] || { echo "0 B"; return; }
    if   [[ $size -ge 1073741824 ]]; then awk "BEGIN {printf \"%.2f GB\", $size/1073741824}"
    elif [[ $size -ge 1048576    ]]; then awk "BEGIN {printf \"%.2f MB\", $size/1048576}"
    elif [[ $size -ge 1024       ]]; then awk "BEGIN {printf \"%.2f KB\", $size/1024}"
    else echo "${size} B"
    fi
}

cleanup() {
    local csv="${CLEANUP_RULES:-}"
    if [[ -z "$csv" ]]; then
        log_message "CLEANUP_RULES is empty, nothing to clean" "debug"
        return 0
    fi

    local total_size=0 total_deleted=0
    declare -A cat_count=()

    _delete_file() {
        local f="$1" cat="$2"
        [[ -f "$f" ]] || return 1
        local sz; sz=$(_stat_size "$f")
        if rm -f "$f"; then
            total_size=$((total_size + sz))
            cat_count[$cat]=$(( ${cat_count[$cat]:-0} + 1 ))
            ((total_deleted++))
            log_message "Deleted: $f" "debug"
        else
            log_message "Failed to delete: $f" "error"
        fi
    }

    # Split rules on comma — temporarily swap IFS
    local start_ts; start_ts=$(date +%s)

    local rule
    while IFS=',' read -ra rules_arr; do
        for rule in "${rules_arr[@]}"; do
            # Trim whitespace
            rule="$(echo "$rule" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
            [[ -z "$rule" ]] && continue

            # Parse fields: name:dirs:patterns:hours:enabled
            local name dirs_field pats_field hours enabled
            IFS=':' read -r name dirs_field pats_field hours enabled <<< "$rule"

            [[ "$enabled" == "true" ]] || continue
            [[ -n "$name" && -n "$dirs_field" && -n "$pats_field" ]] || continue

            hours="${hours:-0}"

            local -a dirs=() pats=()
            IFS='|' read -ra dirs <<< "$dirs_field"
            IFS='|' read -ra pats <<< "$pats_field"

            [[ ${#dirs[@]} -eq 0 || ${#pats[@]} -eq 0 ]] && continue

            # Build find -name expression
            local -a name_expr=()
            local first=true p
            for p in "${pats[@]}"; do
                $first || name_expr+=("-o")
                name_expr+=("-name" "$p")
                first=false
            done

            local dir
            for dir in "${dirs[@]}"; do
                dir="$(echo "$dir" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
                [[ -d "$dir" ]] || continue

                local -a find_cmd=(find "$dir" -type f '(' "${name_expr[@]}" ')')
                [[ $hours -gt 0 ]] && find_cmd+=(-mmin "+$((hours * 60))")
                find_cmd+=(-print0)

                while IFS= read -r -d '' f; do
                    _delete_file "$f" "$name"
                done < <("${find_cmd[@]}" 2>/dev/null)
            done
        done
    done <<< "$csv"

    local end_ts duration
    end_ts=$(date +%s)
    duration=$((end_ts - start_ts))

    if [[ $total_deleted -gt 0 ]]; then
        log_message "Cleanup: removed ${total_deleted} file(s), freed $(_format_size "$total_size") in ${duration}s" "success"
        local cat
        for cat in "${!cat_count[@]}"; do
            [[ ${cat_count[$cat]:-0} -gt 0 ]] && log_message "  ${cat}: ${cat_count[$cat]} file(s)" "debug"
        done
    else
        log_message "Cleanup: nothing to remove" "debug"
    fi
}
