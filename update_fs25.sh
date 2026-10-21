#!/bin/bash
# Headless FS25 update manager for the Pelican container.
#
# Two jobs, both running in the background:
#
#   1. Boot-time update (AUTO_UPDATE != "0"):
#      checks the latest public patch on farming-simulator.com/updates.php
#      against the version stored in game/VERSION. If the game is behind,
#      it drives the GIANTS launcher GUI through Xvnc (xdotool): the
#      launcher performs its own update check, shows "Update Available",
#      and the script clicks Install, waits for completion, then asks
#      supervisor to restart the game stack so the dedicated server comes
#      back on the new version.
#
#   2. Periodic check (UPDATE_CHECK_INTERVAL, default 6h):
#      cheap HTTP re-check while the server is running. It NEVER updates a
#      live server; it only refreshes .server-version.json so the panel
#      banner can tell the user a restart will apply the update.
#
# State is reported in /home/container/.server-version.json (server volume
# root) so a panel plugin can read it via the Wings file API.

set -u

LOG="/home/container/update.log"
STATE="/home/container/.server-version.json"
LOCK="/home/container/.fs25-update.lock"
GAME_DIR="/opt/fs25/game/Farming Simulator 2025"
GAME_EXE="${GAME_DIR}/FarmingSimulator2025.exe"
DEDI_EXE="${GAME_DIR}/dedicatedServer.exe"
VERSION_FILE="${GAME_DIR}/VERSION"
CONFIG_DIR="/opt/fs25/config/FarmingSimulator2025"
WINEPREFIX="/home/container/.fs25server"
CHECK_INTERVAL="${UPDATE_CHECK_INTERVAL:-21600}"

export DISPLAY=:0
export WINEPREFIX WINEARCH=win64 WINEDEBUG=-all WINEDLLOVERRIDES=mscoree=d USER=nobody

# Lines land in update.log; init.sh tails that file to the container
# console with a [fs25-update] prefix.
log() {
    echo "[$(date -Iseconds)] $1" >> "$LOG"
}

# --- helpers ---------------------------------------------------------------

installed_version() {
    tr -d '[:space:]' < "$VERSION_FILE" 2>/dev/null
}

# Latest public FS25 patch from farming-simulator.com/updates.php.
latest_version() {
    curl -fsS --max-time 20 -A 'Mozilla/5.0' \
        'https://farming-simulator.com/updates.php?lang=en&game=fs25' 2>/dev/null \
        | grep -o 'Update [0-9][0-9.]*' | head -1 | awk '{print $2}'
}

# version compare: returns 0 if $1 < $2 (dotted quads, missing parts = 0)
version_lt() {
    [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -1)" != "$2" ] && [ "$1" != "$2" ]
}

write_state() {
    # args: installed latest update_available auto_update note
    local inst="$1" lat="$2" avail="$3" auto="$4" note="${5:-}"
    printf '{"game":"fs25","installed":"%s","latest":"%s","update_available":%s,"auto_update":%s,"checked_at":"%s"%s}\n' \
        "$inst" "$lat" "$avail" "$auto" "$(date -Iseconds)" \
        "$( [ -n "$note" ] && printf ',"note":"%s"' "$note" )" > "$STATE.tmp"
    mv "$STATE.tmp" "$STATE"
    chmod 644 "$STATE" 2>/dev/null || true
}

wait_x() {
    for _ in $(seq 1 90); do
        xdotool getdisplaygeometry >/dev/null 2>&1 && return 0
        sleep 2
    done
    return 1
}

wait_prefix() {
    local link="${WINEPREFIX}/drive_c/users/nobody/Documents/My Games/FarmingSimulator2025"
    for _ in $(seq 1 180); do
        [ -f "${WINEPREFIX}/system.reg" ] && [ -L "$link" ] && return 0
        if [ -f "${WINEPREFIX}/system.reg" ] && [ -d "$link" ] && [ ! -L "$link" ]; then
            mkdir -p "$CONFIG_DIR"
            cp -an "$link/." "$CONFIG_DIR/" 2>/dev/null || true
            rm -rf "$link"
        fi
        if [ -f "${WINEPREFIX}/system.reg" ]; then
            USER=nobody HOME=/home/container /usr/local/bin/wine_symlinks.sh >/dev/null 2>&1 || true
        fi
        sleep 2
    done
    return 1
}

activated() {
    find "$CONFIG_DIR" -maxdepth 1 -name 'AHC_*.dat' | grep -q . \
        && find "$CONFIG_DIR" -maxdepth 1 -name 'AHT_*.dat' | grep -q .
}

find_launcher_window() {
    xdotool search --name 'FarmingSimulator2025' 2>/dev/null | head -1
}

# Click the primary CTA at the bottom right of the 755x377 launcher dialog
# ("Activate >" on the key form, "Install" on the update screen).
click_primary_cta() {
    local win="$1"
    xdotool windowactivate --sync "$win" 2>/dev/null || true
    xdotool windowfocus --sync "$win" 2>/dev/null || true
    sleep 1
    eval "$(xdotool getwindowgeometry --shell "$win" 2>/dev/null || echo 'X=0;Y=0;WIDTH=755;HEIGHT=377')"
    xdotool mousemove $((X + WIDTH * 81 / 100)) $((Y + HEIGHT * 93 / 100)) click 1 2>/dev/null || true
}

kill_launcher() {
    pkill -f 'FarmingSimulator2025\.exe' 2>/dev/null || true
    pkill -f 'GiantsCrashReporter\.exe' 2>/dev/null || true
}

# Drives the GIANTS launcher through the update flow.
# Returns 0 if an update was applied, 1 on failure.
run_gui_update() {
    local before after win i
    before="$(installed_version)"

    # Stamp the updater log so we can detect a fresh update check.
    local stamp
    stamp=$(stat -c %s "${CONFIG_DIR}/updater/updater.00.log" 2>/dev/null || echo 0)

    log "Launching GIANTS launcher for update"
    nohup wine "$GAME_EXE" >> "$LOG" 2>&1 &
    local lpid=$!

    # Wait for the launcher window AND the updater's own check to finish.
    win=""
    for i in $(seq 1 90); do
        win=$(find_launcher_window)
        [ -n "$win" ] && break
        kill -0 "$lpid" 2>/dev/null || { log "ERROR: launcher exited early"; return 1; }
        sleep 2
    done
    [ -z "$win" ] && { log "ERROR: launcher window not found"; kill_launcher; return 1; }
    log "Launcher window ready (id=$win)"

    # Give the updater time to run its check (fresh lines in updater.00.log
    # past our stamp) and the window to render its Update Available state.
    for i in $(seq 1 60); do
        local cur
        cur=$(stat -c %s "${CONFIG_DIR}/updater/updater.00.log" 2>/dev/null || echo 0)
        [ "$cur" != "$stamp" ] && sleep 15 && break
        sleep 2
    done

    click_primary_cta "$win"
    log "Install requested, waiting for update to finish"

    # Wait until VERSION changes (success) or bounded timeout (~45 min for
    # ~2GB downloads on slow links).
    for i in $(seq 1 540); do
        after="$(installed_version)"
        [ -n "$after" ] && [ "$after" != "$before" ] && break
        # Re-click Install occasionally in case the first click landed too
        # early on the still-rendering window.
        if [ $((i % 60)) -eq 0 ]; then
            win=$(find_launcher_window)
            [ -n "$win" ] && click_primary_cta "$win"
        fi
        kill -0 "$lpid" 2>/dev/null || break
        sleep 5
    done

    after="$(installed_version)"
    kill_launcher

    if [ -n "$after" ] && [ "$after" != "$before" ]; then
        log "Update applied: ${before} -> ${after}"
        return 0
    fi
    log "ERROR: update did not complete (VERSION still '${after}')"
    return 1
}

# --- main ------------------------------------------------------------------

log "Update manager started (AUTO_UPDATE=${AUTO_UPDATE:-unset})"

# Single instance guard.
exec 9>"$LOCK"
if ! flock -n 9; then
    log "Another update manager is already running, exiting"
    exit 0
fi

# Wait for the game + activation before doing anything.
for _ in $(seq 1 360); do
    [ -f "$DEDI_EXE" ] && [ -f "$VERSION_FILE" ] && break
    sleep 5
done
[ -f "$DEDI_EXE" ] || { log "ERROR: game not installed"; exit 1; }

for _ in $(seq 1 360); do
    activated && break
    sleep 5
done
ACTIVATED=true
if ! activated; then
    ACTIVATED=false
    log "License not activated yet, GUI update unavailable (activation helper handles it)"
fi

AUTO_JSON=false
case "${AUTO_UPDATE:-1}" in
    1|true|yes) AUTO_JSON=true ;;
esac

INST="$(installed_version)"
LATEST="$(latest_version)"
log "Installed version: ${INST:-unknown}, latest public patch: ${LATEST:-unreachable}"

if [ -z "$LATEST" ]; then
    write_state "${INST:-}" "" false "$AUTO_JSON" "latest check unreachable"
elif version_lt "$INST" "$LATEST" && $AUTO_JSON && $ACTIVATED; then
    wait_x || { log "ERROR: X server not available"; write_state "$INST" "$LATEST" true "$AUTO_JSON" "no X server"; exit 1; }
    wait_prefix || { log "ERROR: wine prefix/symlink not ready"; write_state "$INST" "$LATEST" true "$AUTO_JSON" "no prefix"; exit 1; }
    if run_gui_update; then
        NEW="$(installed_version)"
        write_state "$NEW" "$LATEST" false "$AUTO_JSON" "updated from $INST"
        log "Restarting game stack on new version"
        supervisorctl -c /etc/supervisord.conf restart start >/dev/null 2>&1 || true
        INST="$NEW"
    else
        write_state "$INST" "$LATEST" true "$AUTO_JSON" "gui update failed"
    fi
elif version_lt "$INST" "$LATEST"; then
    write_state "$INST" "$LATEST" true "$AUTO_JSON" "auto update disabled"
else
    write_state "$INST" "$LATEST" false "$AUTO_JSON"
fi

# Periodic re-check while running: refresh state only, never update live.
while :; do
    sleep "$CHECK_INTERVAL"
    INST="$(installed_version)"
    LATEST="$(latest_version)"
    [ -z "$LATEST" ] && continue
    if version_lt "$INST" "$LATEST"; then
        log "Update available while running: ${INST} -> ${LATEST} (restart to apply)"
        write_state "$INST" "$LATEST" true "$AUTO_JSON" "restart to update"
    else
        write_state "$INST" "$LATEST" false "$AUTO_JSON"
    fi
done
