#!/bin/bash
# entrypoint.sh — Insanity Gaming CS2 server entry point

source /utils.sh
source /cleanup.sh
source /modsharp.sh

trap 'log_message "Error on line ${LINENO}: ${BASH_COMMAND}" "error"' ERR

cd /home/container || exit 1

mkdir -p "$EGG_DIR" "$TEMP_DIR"

# Rotate old log files before anything else
rotate_logs

# ── SteamCMD bootstrap ────────────────────────────────────────────────────────
install_steamcmd() {
    if [[ -f "./steamcmd/steamcmd.sh" ]]; then
        log_message "SteamCMD already installed" "debug"
        return 0
    fi

    log_message "Installing SteamCMD..." "running"
    mkdir -p ./steamcmd

    local url="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"
    local dl="${TEMP_DIR}/steamcmd_linux.tar.gz"

    if handle_download_and_extract "$url" "$dl" "./steamcmd" "tar.gz"; then
        rm -f "$dl"
        chmod +x ./steamcmd/steamcmd.sh
        log_message "SteamCMD installed" "success"
        return 0
    else
        log_message "Failed to install SteamCMD" "error"
        rm -f "$dl"
        return 1
    fi
}

if [[ "${SRCDS_STOP_UPDATE:-0}" -eq 0 ]]; then
    install_steamcmd || { log_message "Cannot proceed without SteamCMD" "error"; exit 1; }
fi

# ── SteamCMD ──────────────────────────────────────────────────────────────────
if [[ "${SRCDS_STOP_UPDATE:-0}" -eq 0 ]]; then
    log_message "Running SteamCMD update..." "running"

    local_cmd="./steamcmd/steamcmd.sh +login anonymous"
    local_cmd+=" +force_install_dir /home/container +app_update ${SRCDS_APPID:-730}"

    if [[ "${SRCDS_VALIDATE:-0}" -eq 1 ]]; then
        local_cmd+=" validate"
        log_message "Validation enabled — custom files may be overwritten. Starting in 5s..." "warning"
        sleep 5
    fi

    local_cmd+=" +quit"

    trap - ERR
    eval "$local_cmd"
    STEAM_EXIT=$?
    trap 'log_message "Error on line ${LINENO}: ${BASH_COMMAND}" "error"' ERR

    case $STEAM_EXIT in
        0)  log_message "SteamCMD completed" "success" ;;
        8)  log_message "SteamCMD connection error (exit 8) — server may be outdated" "warning" ;;
        *)  log_message "SteamCMD exited with code ${STEAM_EXIT}" "warning" ;;
    esac

    # Keep steamclient.so in sync
    cp -f ./steamcmd/linux32/steamclient.so ./.steam/sdk32/steamclient.so 2>/dev/null || true
    cp -f ./steamcmd/linux64/steamclient.so ./.steam/sdk64/steamclient.so 2>/dev/null || true
fi

# ── Base map purge ─────────────────────────────────────────────────────────────
purge_base_maps() {
    [[ "${PURGE_BASE_MAPS:-0}" -eq 1 ]] || return 0

    if [[ ! -d ./game/csgo/maps ]]; then
        log_message "maps directory not found, skipping purge" "debug"
        return 0
    fi

    local count f
    count=0

    while IFS= read -r -d '' f; do
        rm -f "$f" && ((count++)) || log_message "Failed to delete: $f" "error"
    done < <(find ./game/csgo/maps -maxdepth 1 -name '*.vpk' ! -name 'de_dust2*' -type f -print0 2>/dev/null)

    if [[ $count -gt 0 ]]; then
        log_message "Purged ${count} base map .vpk file(s) from game/csgo/maps (de_dust2 kept)" "info"
    else
        log_message "No base map .vpk files to purge" "debug"
    fi
}

purge_base_maps

# ── ModSharp ───────────────────────────────────────────────────────────────────
if [[ "${INSTALL_MODSHARP:-0}" -eq 1 ]]; then
    mkdir -p "$TEMP_DIR"
    if update_modsharp; then
        add_to_gameinfo "sharp"
        patch_tokenless_setting
    else
        log_message "ModSharp update failed — server will start with existing install (if any)" "warning"
    fi
    rm -rf "$TEMP_DIR"
else
    patch_tokenless_setting
fi

# ── Cleanup ────────────────────────────────────────────────────────────────────
if [[ "${CLEANUP_ENABLED:-0}" -eq 1 ]]; then
    cleanup
fi

# ── Console filter setup ───────────────────────────────────────────────────────
FILTER_EXACT=()
FILTER_CONTAINS=()

setup_filter() {
    local csv="${FILTER_PATTERNS:-}"
    [[ -z "$csv" ]] && return 0

    local entry
    IFS=',' read -ra entries <<< "$csv"
    for entry in "${entries[@]}"; do
        entry="$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$entry" ]] && continue
        if [[ "$entry" == @* ]]; then
            FILTER_EXACT+=("${entry:1}")
        else
            FILTER_CONTAINS+=("$entry")
        fi
    done

    local total=$(( ${#FILTER_EXACT[@]} + ${#FILTER_CONTAINS[@]} ))
    log_message "Console filter active: ${total} pattern(s)" "info"
}

handle_server_output() {
    local line="$1"

    # Always mask secrets
    line="$(mask_secrets "$line")"

    if [[ "${ENABLE_FILTER:-0}" -eq 1 ]]; then
        local exact
        for exact in "${FILTER_EXACT[@]}"; do
            if [[ "$line" == "$exact" ]]; then
                [[ "${FILTER_PREVIEW_MODE:-0}" -eq 1 ]] && log_message "[filtered] ${line}" "debug"
                return 0
            fi
        done

        local sub
        for sub in "${FILTER_CONTAINS[@]}"; do
            if [[ "$line" == *"$sub"* ]]; then
                [[ "${FILTER_PREVIEW_MODE:-0}" -eq 1 ]] && log_message "[filtered] ${line}" "debug"
                return 0
            fi
        done
    fi

    echo "$line"
}

if [[ "${ENABLE_FILTER:-0}" -eq 1 ]]; then
    setup_filter
fi

# ── Build startup command ──────────────────────────────────────────────────────
MODIFIED_STARTUP=$(eval echo "$(echo "${STARTUP}" | sed -e 's/{{/${/g' -e 's/}}/}/g')")
log_message "Starting: ${MODIFIED_STARTUP}" "info"

# ── Launch server ──────────────────────────────────────────────────────────────
eval "script -qfc \"${MODIFIED_STARTUP}\" /dev/null 2>&1" | while IFS= read -r line; do
    line="${line%[[:space:]]}"

    # Suppress segfault spam from cs2.sh wrapper
    [[ "$line" =~ Segmentation\ fault.*"${GAMEEXE:-cs2}" ]] && continue

    # Crash detection
    if [[ "$line" =~ \./game/cs2\.sh:.*Aborted.*\(core\ dumped\) ]]; then
        handle_server_output "$line"
        log_message "Server crash detected — check the stack trace above for the failing module" "warning"
        continue
    fi

    # GSLT rejection
    if [[ "$line" == *"Cert request for invalid failed"* || "$line" == *"We're not logged into Steam"* ]]; then
        handle_server_output "$line"
        log_message "GSLT token invalid or expired — regenerate at https://steamcommunity.com/dev/managegameservers (App ID 730)" "warning"
        continue
    fi

    handle_server_output "$line"
done

pkill -P $$ 2>/dev/null || true
log_message "Server stopped" "info"
