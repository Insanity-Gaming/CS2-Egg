#!/bin/bash
# utils.sh — logging, versioning, download, gameinfo helpers

# ── Colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
GRAY='\033[0;90m'
NC='\033[0m'

# ── Constants ─────────────────────────────────────────────────────────────────
EGG_DIR="${EGG_DIR:-/home/container/egg}"
EGG_LOGS_DIR="${EGG_DIR}/logs"
VERSION_FILE="${EGG_DIR}/versions.txt"
export TEMP_DIR="/home/container/temps"

PREFIX_TEXT="${PREFIX_TEXT:-InsanityGaming}"

# ── Logging ───────────────────────────────────────────────────────────────────
_level_priority() {
    case "$(echo "${1:-INFO}" | tr '[:lower:]' '[:upper:]')" in
        DEBUG)   echo 0 ;;
        INFO)    echo 1 ;;
        WARNING) echo 2 ;;
        ERROR)   echo 3 ;;
        *)       echo 1 ;;
    esac
}

log_message() {
    local message="$1"
    local type="${2:-info}"

    local msg_pri level_pri
    case "$type" in
        debug)   msg_pri=0 ;;
        info)    msg_pri=1 ;;
        running) msg_pri=1 ;;
        success) msg_pri=1 ;;
        warning) msg_pri=2 ;;
        error)   msg_pri=3 ;;
        *)       msg_pri=1 ;;
    esac

    level_pri=$(_level_priority "${LOG_LEVEL:-INFO}")
    [[ $msg_pri -ge $level_pri ]] || return 0

    message="${message%[[:space:]]}"

    # Mask secrets before printing
    if declare -F mask_secrets >/dev/null 2>&1; then
        message="$(mask_secrets "$message")"
    fi

    local tag color
    case "$type" in
        info)    tag="INFO ";  color="$CYAN"   ;;
        success) tag="OK   ";  color="$GREEN"  ;;
        warning) tag="WARN ";  color="$YELLOW" ;;
        error)   tag="ERROR";  color="$RED"    ;;
        debug)   tag="DEBUG";  color="$GRAY"   ;;
        running) tag="RUN  ";  color="$YELLOW" ;;
        *)       tag="INFO ";  color="$CYAN"   ;;
    esac

    local sep
    sep=$(printf '%b|%b' "$GRAY" "$NC")

    printf "%b%s%b %s %b%s%b %s %b%s%b\n" \
        "$RED" "$PREFIX_TEXT" "$NC" \
        "$sep" \
        "$color" "$tag" "$NC" \
        "$sep" \
        "$color" "$message" "$NC"

    # File logging
    if [[ "${LOG_FILE_ENABLED:-0}" == "1" || "${LOG_FILE_ENABLED:-0}" == "true" ]]; then
        mkdir -p "$EGG_LOGS_DIR"
        local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
        echo "[$ts] [$type] $message" >> "${EGG_LOGS_DIR}/$(date '+%Y-%m-%d').log"
    fi
}

rotate_logs() {
    [[ "${LOG_FILE_ENABLED:-0}" == "1" || "${LOG_FILE_ENABLED:-0}" == "true" ]] || return 0
    [[ -d "$EGG_LOGS_DIR" ]] || return 0

    local max_days="${LOG_MAX_DAYS:-7}"
    local max_files="${LOG_MAX_FILES:-30}"
    local max_mb="${LOG_MAX_SIZE_MB:-100}"

    [[ $max_days -gt 0 ]] && find "$EGG_LOGS_DIR" -name "*.log" -type f -mtime "+${max_days}" -delete 2>/dev/null

    if [[ $max_files -gt 0 ]]; then
        local count; count=$(find "$EGG_LOGS_DIR" -name "*.log" -type f | wc -l)
        if [[ $count -gt $max_files ]]; then
            find "$EGG_LOGS_DIR" -name "*.log" -type f -printf '%T+ %p\n' \
                | sort | head -n $((count - max_files)) | cut -d' ' -f2- | xargs -r rm -f
        fi
    fi

    if [[ $max_mb -gt 0 ]]; then
        local kb max_kb
        kb=$(du -sk "$EGG_LOGS_DIR" | cut -f1)
        max_kb=$((max_mb * 1024))
        while [[ $kb -gt $max_kb ]]; do
            local oldest
            oldest=$(find "$EGG_LOGS_DIR" -name "*.log" -type f -printf '%T+ %p\n' | sort | head -n1 | cut -d' ' -f2-)
            [[ -z "$oldest" ]] && break
            rm -f "$oldest"
            kb=$(du -sk "$EGG_LOGS_DIR" | cut -f1)
        done
    fi
}

# ── Secret masking ────────────────────────────────────────────────────────────
mask_secrets() {
    local line="$1"
    if [[ -n "${STEAM_ACC:-}" ]]; then
        line="${line//${STEAM_ACC}/****}"
    fi
    echo "$line"
}

# ── Semver compare ────────────────────────────────────────────────────────────
# Returns 0 = equal, 1 = v1 > v2, 2 = v1 < v2
semver_compare() {
    local v1="${1#v}" v2="${2#v}"
    [[ "$v1" == "$v2" ]] && return 0
    local highest; highest=$(printf "%s\n%s" "$v1" "$v2" | sort -V | tail -n1)
    [[ "$v1" == "$highest" ]] && return 1 || return 2
}

# ── Version file ──────────────────────────────────────────────────────────────
get_current_version() {
    local addon="$1"
    [[ -f "$VERSION_FILE" ]] && grep "^${addon}=" "$VERSION_FILE" | cut -d'=' -f2 || echo ""
}

update_version_file() {
    local addon="$1" ver="$2"
    mkdir -p "$(dirname "$VERSION_FILE")"
    if [[ -f "$VERSION_FILE" ]] && grep -q "^${addon}=" "$VERSION_FILE"; then
        sed -i.bak "s/^${addon}=.*/${addon}=${ver}/" "$VERSION_FILE" && rm -f "${VERSION_FILE}.bak"
    else
        echo "${addon}=${ver}" >> "$VERSION_FILE"
    fi
}

# ── GitHub release fetch ──────────────────────────────────────────────────────
# Outputs JSON: {version, asset_url, asset_name, is_prerelease}
get_github_release() {
    local repo="$1" asset_pattern="${2:-.*}"
    local url="https://api.github.com/repos/${repo}/releases"

    if [[ "${PRERELEASE:-0}" == "1" ]]; then
        log_message "Checking releases (prereleases enabled) for ${repo}" "debug"
    else
        url="${url}/latest"
        log_message "Checking latest stable release for ${repo}" "debug"
    fi

    curl -fsSL -m 30 "$url" 2>/dev/null | jq --arg p "$asset_pattern" '
        (if type == "array" then .[0] else . end) // empty |
        {
            version:       .tag_name,
            is_prerelease: .prerelease,
            asset_url:     (first(.assets[] | select(.name | test($p)) | .browser_download_url) // ""),
            asset_name:    (first(.assets[] | select(.name | test($p)) | .name) // "")
        }
    ' 2>/dev/null
}

# ── Download + extract ────────────────────────────────────────────────────────
# file_type: "zip" or "tar.gz"
handle_download_and_extract() {
    local url="$1" output_file="$2" extract_dir="$3" file_type="$4"

    local -a mirrors=("$url")
    if [[ "$url" == *"github.com"* || "$url" == *"githubusercontent.com"* ]]; then
        mirrors+=("https://ghproxy.net/${url}" "https://gh.llkk.cc/${url}")
    fi

    local ok=false
    for mirror in "${mirrors[@]}"; do
        log_message "Downloading: ${mirror}" "debug"
        if curl -fsSL -m 300 -A "Mozilla/5.0" -o "$output_file" "$mirror"; then
            ok=true
            break
        fi
        log_message "Download failed, trying next mirror..." "warning"
    done

    if ! $ok; then
        log_message "All download sources failed" "error"
        return 1
    fi

    if [[ ! -s "$output_file" ]]; then
        log_message "Downloaded file is empty" "error"
        return 1
    fi

    mkdir -p "$extract_dir"

    case "$file_type" in
        zip)
            unzip -qq -o "$output_file" -d "$extract_dir" || { log_message "Failed to extract zip" "error"; return 1; }
            ;;
        tar.gz)
            tar -xzf "$output_file" -C "$extract_dir" || { log_message "Failed to extract tar.gz" "error"; return 1; }
            ;;
        *)
            log_message "Unknown file type: ${file_type}" "error"
            return 1
            ;;
    esac

    return 0
}

# ── gameinfo.gi helpers ───────────────────────────────────────────────────────
GAMEINFO_FILE="/home/container/game/csgo/gameinfo.gi"

add_to_gameinfo() {
    local addon_path="$1"

    if [[ ! -f "$GAMEINFO_FILE" ]]; then
        log_message "gameinfo.gi not found" "error"
        return 1
    fi

    if grep -q "Game[[:blank:]]*${addon_path}" "$GAMEINFO_FILE"; then
        log_message "${addon_path} already in gameinfo.gi" "debug"
        return 0
    fi

    log_message "Adding ${addon_path} to gameinfo.gi..." "info"

    cp "$GAMEINFO_FILE" "${GAMEINFO_FILE}.bak" || { log_message "Failed to backup gameinfo.gi" "error"; return 1; }

    sed "/Game_LowViolence/a\\
            Game    ${addon_path}" "${GAMEINFO_FILE}.bak" > "$GAMEINFO_FILE"

    if grep -q "Game[[:space:]]*${addon_path}" "$GAMEINFO_FILE"; then
        log_message "Added ${addon_path} to gameinfo.gi" "success"
        rm -f "${GAMEINFO_FILE}.bak"
        return 0
    else
        log_message "Failed to add ${addon_path} to gameinfo.gi, restoring backup" "error"
        mv "${GAMEINFO_FILE}.bak" "$GAMEINFO_FILE"
        return 1
    fi
}

remove_from_gameinfo() {
    local addon_path="$1"

    if [[ ! -f "$GAMEINFO_FILE" ]]; then
        log_message "gameinfo.gi not found" "debug"
        return 0
    fi

    if ! grep -q "Game[[:blank:]]*${addon_path}" "$GAMEINFO_FILE"; then
        log_message "${addon_path} not in gameinfo.gi, nothing to remove" "debug"
        return 0
    fi

    log_message "Removing ${addon_path} from gameinfo.gi..." "info"

    cp "$GAMEINFO_FILE" "${GAMEINFO_FILE}.bak" || { log_message "Failed to backup gameinfo.gi" "error"; return 1; }

    sed "/Game[[:blank:]]*${addon_path}/d" "${GAMEINFO_FILE}.bak" > "$GAMEINFO_FILE"

    if ! grep -q "Game[[:blank:]]*${addon_path}" "$GAMEINFO_FILE"; then
        log_message "Removed ${addon_path} from gameinfo.gi" "success"
        rm -f "${GAMEINFO_FILE}.bak"
        return 0
    else
        log_message "Failed to remove ${addon_path} from gameinfo.gi, restoring backup" "error"
        mv "${GAMEINFO_FILE}.bak" "$GAMEINFO_FILE"
        return 1
    fi
}

patch_tokenless_setting() {
    [[ -f "$GAMEINFO_FILE" ]] || return 0

    local desired
    desired=$([[ "${ALLOW_TOKENLESS:-0}" -eq 1 ]] && echo "0" || echo "1")

    local current
    current=$(grep -oP 'RequireLoginForDedicatedServers"\s+"\K[0-9]+' "$GAMEINFO_FILE" 2>/dev/null)

    if [[ "$current" == "$desired" ]]; then
        log_message "RequireLoginForDedicatedServers already ${desired}" "debug"
        return 0
    fi

    cp "$GAMEINFO_FILE" "${GAMEINFO_FILE}.bak" || { log_message "Failed to backup gameinfo.gi" "error"; return 1; }

    sed -i "s/\(RequireLoginForDedicatedServers\"[[:space:]]*\)\"[0-9]\"/\1\"${desired}\"/" "$GAMEINFO_FILE"

    local new
    new=$(grep -oP 'RequireLoginForDedicatedServers"\s+"\K[0-9]+' "$GAMEINFO_FILE" 2>/dev/null)
    if [[ "$new" == "$desired" ]]; then
        rm -f "${GAMEINFO_FILE}.bak"
        return 0
    else
        log_message "Failed to patch RequireLoginForDedicatedServers, restoring backup" "error"
        mv "${GAMEINFO_FILE}.bak" "$GAMEINFO_FILE"
        return 1
    fi
}
