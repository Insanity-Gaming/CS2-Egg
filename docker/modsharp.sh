#!/bin/bash
# modsharp.sh — .NET 10 runtime + ModSharp install/update + extract blocklist

source /utils.sh

MODSHARP_DIR="/home/container/game/sharp"
DOTNET_VERSION="10.0.0"

install_dotnet_runtime() {
    local runtime_dir="${MODSHARP_DIR}/runtime"
    local current; current=$(get_current_version "DotNet")

    if [[ "$current" == "$DOTNET_VERSION" && -f "${runtime_dir}/dotnet" ]]; then
        log_message ".NET runtime already up to date (${DOTNET_VERSION})" "debug"
        return 0
    fi

    log_message "Installing .NET ${DOTNET_VERSION} runtime..." "running"

    mkdir -p "$runtime_dir"

    local url="https://dotnetcli.azureedge.net/dotnet/Runtime/${DOTNET_VERSION}/dotnet-runtime-${DOTNET_VERSION}-linux-x64.tar.gz"
    local dl="${TEMP_DIR}/dotnet-runtime.tar.gz"

    if handle_download_and_extract "$url" "$dl" "$runtime_dir" "tar.gz"; then
        update_version_file "DotNet" "$DOTNET_VERSION"
        log_message ".NET ${DOTNET_VERSION} runtime installed" "success"
        rm -f "$dl"
        return 0
    else
        log_message "Failed to install .NET runtime" "error"
        rm -f "$dl"
        return 1
    fi
}

apply_extract_blocklist() {
    local csv="${MODSHARP_EXTRACT_BLOCKLIST:-}"
    [[ -z "$csv" ]] && return 0

    local removed=0
    local entry
    IFS=',' read -ra entries <<< "$csv"
    for entry in "${entries[@]}"; do
        entry="$(echo "$entry" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
        [[ -z "$entry" ]] && continue

        local full_path="./game/${entry}"
        if [[ -e "$full_path" ]]; then
            rm -rf "$full_path"
            log_message "Blocked: ${entry}" "info"
            ((removed++))
        else
            log_message "Blocklist: ${entry} not found (skipped)" "debug"
        fi
    done

    [[ $removed -gt 0 ]] && log_message "Blocklist removed ${removed} path(s)" "info"
}

update_modsharp() {
    # Step 1: .NET runtime
    install_dotnet_runtime || return 1

    # Step 2: Fetch release info
    local repo="Kxnrl/modsharp-public"
    local api_url="https://api.github.com/repos/${repo}/releases"
    local release_info

    if [[ "${PRERELEASE:-0}" == "1" ]]; then
        release_info=$(curl -fsSL -m 30 "$api_url" 2>/dev/null | jq '.[0] // empty')
    else
        release_info=$(curl -fsSL -m 30 "${api_url}/latest" 2>/dev/null)
    fi

    if [[ -z "$release_info" ]] || ! echo "$release_info" | jq -e . >/dev/null 2>&1; then
        log_message "Failed to fetch ModSharp release info" "error"
        return 1
    fi

    local latest_version core_url extensions_url
    latest_version=$(echo "$release_info" | jq -r '.tag_name // empty' | sed 's/-//g')
    core_url=$(echo "$release_info" | jq -r '.assets[] | select(.name | contains("linux.zip") and (contains("extensions") | not)) | .browser_download_url')
    extensions_url=$(echo "$release_info" | jq -r '.assets[] | select(.name | contains("linux-extensions.zip")) | .browser_download_url')

    if [[ -z "$latest_version" || -z "$core_url" || -z "$extensions_url" ]]; then
        log_message "Could not parse ModSharp release data" "error"
        return 1
    fi

    # Step 3: Version check
    local current; current=$(get_current_version "ModSharp")
    log_message "ModSharp current: ${current:-none}  latest: ${latest_version}" "debug"

    if [[ -n "$current" ]]; then
        semver_compare "$latest_version" "$current"
        case $? in
            0) log_message "ModSharp is up-to-date (${current})" "success"; return 0 ;;
            2) log_message "ModSharp local (${current}) is newer than remote (${latest_version}), skipping downgrade" "info"; return 0 ;;
        esac
    fi

    log_message "Updating ModSharp to ${latest_version}..." "running"

    # Step 4: Backup user configs
    local cfg_bak="${TEMP_DIR}/core.json.bak"
    local adm_bak="${TEMP_DIR}/admins.jsonc.bak"
    [[ -f "${MODSHARP_DIR}/configs/core.json"    ]] && cp "${MODSHARP_DIR}/configs/core.json"    "$cfg_bak"
    [[ -f "${MODSHARP_DIR}/configs/admins.jsonc" ]] && cp "${MODSHARP_DIR}/configs/admins.jsonc" "$adm_bak"

    # Step 5: Extract core → ./game/
    local core_dl="${TEMP_DIR}/modsharp-core.zip"
    if ! handle_download_and_extract "$core_url" "$core_dl" "./game/" "zip"; then
        log_message "Failed to install ModSharp core" "error"
        return 1
    fi
    rm -f "$core_dl"

    # Step 6: Extract extensions → ./game/sharp/shared/
    local ext_dl="${TEMP_DIR}/modsharp-extensions.zip"
    if ! handle_download_and_extract "$extensions_url" "$ext_dl" "./game/sharp/shared/" "zip"; then
        log_message "Failed to install ModSharp extensions (non-fatal)" "warning"
    fi
    rm -f "$ext_dl"

    # Step 7: Apply extract blocklist
    apply_extract_blocklist

    # Step 8: Restore user configs
    if [[ -f "$cfg_bak" ]]; then
        mkdir -p "${MODSHARP_DIR}/configs"
        cp "$cfg_bak" "${MODSHARP_DIR}/configs/core.json"
        log_message "Restored core.json" "debug"
        rm -f "$cfg_bak"
    fi
    if [[ -f "$adm_bak" ]]; then
        mkdir -p "${MODSHARP_DIR}/configs"
        cp "$adm_bak" "${MODSHARP_DIR}/configs/admins.jsonc"
        log_message "Restored admins.jsonc" "debug"
        rm -f "$adm_bak"
    fi

    # Step 9: Update version
    update_version_file "ModSharp" "$latest_version"

    log_message "ModSharp updated to ${latest_version}" "success"
    return 0
}
