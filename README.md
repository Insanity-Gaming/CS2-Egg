# Insanity Gaming CS2 Egg

Pterodactyl/Pelican egg for CS2 dedicated servers. SteamRT3 Sniper base, ModSharp support.

## Docker Image

Build from `docker/`:

```bash
docker build -t ghcr.io/insanitygaming/cs2-egg:latest -f docker/Dockerfile docker/
```

## Egg Import

Import `egg/insanity-cs2-egg.json` into your Pterodactyl or Pelican panel.

---

## Variable Reference

### Server

| Variable | Default | Description |
|---|---|---|
| `STEAM_ACC` | _(empty)_ | GSLT token. Leave empty for LAN/private. |
| `SRCDS_MAP` | `de_dust2` | Default map. |
| `GAME_TYPE` | `0` | Game type (0=Classic). |
| `GAME_MODE` | `0` | Game mode. |
| `CUSTOM_PARAMS` | _(empty)_ | Extra command-line args. |

### ModSharp

| Variable | Default | Description |
|---|---|---|
| `INSTALL_MODSHARP` | `0` | Set to `1` to install and auto-update ModSharp. |
| `PRERELEASE` | `0` | Set to `1` to allow prerelease ModSharp builds. |
| `MODSHARP_EXTRACT_BLOCKLIST` | _(empty)_ | CSV of regex patterns. See below. |

### Map Purge

| Variable | Default | Description |
|---|---|---|
| `PURGE_BASE_MAPS` | `0` | Set to `1` to delete `game/csgo/maps/*.vpk` after every SteamCMD update. |

### Console Filter

| Variable | Default | Description |
|---|---|---|
| `ENABLE_FILTER` | `0` | Set to `1` to enable console output filtering. |
| `FILTER_PATTERNS` | `Certificate expires` | CSV of patterns. `@text` = exact, no prefix = substring. |
| `FILTER_PREVIEW_MODE` | `0` | Set to `1` to log filtered lines at DEBUG instead of dropping them. |

### Cleanup

| Variable | Default | Description |
|---|---|---|
| `CLEANUP_ENABLED` | `0` | Set to `1` to run file cleanup on startup. |
| `CLEANUP_RULES` | _(see below)_ | CSV of cleanup rules. |

### Logging

| Variable | Default | Description |
|---|---|---|
| `LOG_LEVEL` | `INFO` | `DEBUG` / `INFO` / `WARNING` / `ERROR` |
| `LOG_FILE_ENABLED` | `0` | Set to `1` to write daily log files to `/home/container/egg/logs/`. |
| `LOG_MAX_SIZE_MB` | `100` | Max total log directory size in MB. |
| `LOG_MAX_FILES` | `30` | Max number of log files. |
| `LOG_MAX_DAYS` | `7` | Max age of log files in days. |

---

## ModSharp Extract Blocklist

After each ModSharp update, each entry is deleted by exact path. Paths are relative to `game/`. Directories are removed recursively. Missing paths are silently skipped.

**Examples:**

```
# Block a specific module directory
sharp/modules/AdminCommands

# Block a specific file
sharp/configs/core.json

# Block multiple (comma-separated)
sharp/modules/AdminCommands,sharp/modules/DefaultChat,sharp/configs/core.json
```

---

## Cleanup Rules Format

`CLEANUP_RULES` is a comma-separated list of rules. Each rule:

```
name:dirs:patterns:hours:enabled
```

- `dirs` — pipe-separated list of directories to search
- `patterns` — pipe-separated list of filename globs
- `hours` — delete files older than N hours (`0` = delete every run)
- `enabled` — `true` or `false`

**Default value:**

```
modsharp_logs:./game/sharp/logs:*.log:72:true,
backup_rounds:./game/csgo:backup_round*.txt:24:true,
demos:./game/csgo:*.dem:168:true,
core_dumps:./game/bin/linuxsteamrt64|/home/container:core|core.[0-9]*:0:true
```

**Custom example** (add an accelerator dumps rule):

```
modsharp_logs:./game/sharp/logs:*.log:72:true,demos:./game/csgo:*.dem:168:true,accel_dumps:./game/csgo/addons/AcceleratorCS2/dumps:*.dmp|*.dmp.txt:168:true
```
