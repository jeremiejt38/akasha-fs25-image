#!/bin/bash
# Headless FS25 update manager for the Pelican container.
#
# Two jobs:
#
#   1. Boot-time update (`--boot`, run synchronously by init.sh BEFORE
#      supervisord starts the game stack). The game and the GIANTS
#      auto-updater share an instance mutex, so the update can ONLY run
#      while no FS25 process exists — doing it here, on a private Xvnc
#      display (:99), is the only window where that is guaranteed.
#      The update itself is fully headless: the self-updated AU worker is
#      invoked directly with `-updateAll`, no GUI clicking involved.
#
#   2. Periodic check (no args, background): cheap HTTP re-check while the
#      server is running. It can NEVER update a live server (mutex); it
#      only refreshes .server-version.json so the panel banner can tell
#      the user a restart will apply the update.
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

BOOT_MODE=0
[ "${1:-}" = "--boot" ] && BOOT_MODE=1

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

kill_fs25() {
    pkill -f 'FarmingSimulator2025\.exe' 2>/dev/null || true
    pkill -f 'GiantsCrashReporter\.exe' 2>/dev/null || true
}

# Path to the self-updated GIANTS auto-updater worker. The launcher
# refreshes its own copy into updater/<activation-hash>/ and then spawns
# it with `-gamePath … -userProfilePath … -updateAll` — invoking that copy
# directly is the supported headless update path (no GUI automation).
au_worker_exe() {
    find "$CONFIG_DIR/updater" -mindepth 2 -maxdepth 2 -type f \
        -name 'FarmingSimulator2025.exe' -printf '%T@ %p\n' 2>/dev/null \
        | sort -rn | head -1 | cut -d' ' -f2-
}

# Runs the GIANTS AU worker headlessly with `-updateAll`.
# Returns 0 if an update was applied, 1 on failure.
run_headless_update() {
    local before after worker
    before="$(installed_version)"

    worker="$(au_worker_exe)"
    if [ -z "$worker" ]; then
        # No self-updated worker copy yet — let the launcher run once so
        # it drops updater/<hash>/FarmingSimulator2025.exe, then retry.
        log "No self-updated AU worker yet, priming the launcher once"
        timeout 180 wine "$GAME_EXE" >> "$LOG" 2>&1 || true
        kill_fs25
        worker="$(au_worker_exe)"
        [ -z "$worker" ] && { log "ERROR: AU worker unavailable after priming"; return 1; }
    fi

    log "Running AU worker headless (-updateAll)"
    wine "$worker" \
        -gamePath "Z:/opt/fs25/game/Farming Simulator 2025/" \
        -userProfilePath "C:/users/nobody/Documents/My Games/FarmingSimulator2025/" \
        -updateAll >> "$LOG" 2>&1 &
    local wpid=$!

    # The worker exits on its own once the patch is installed (or when
    # nothing needs doing). Bound the wait at ~60 min for multi-GB
    # downloads on slow links.
    for _ in $(seq 1 720); do
        kill -0 "$wpid" 2>/dev/null || break
        sleep 5
    done
    wait "$wpid" 2>/dev/null || true

    after="$(installed_version)"
    if [ -n "$after" ] && [ "$after" != "$before" ]; then
        # Give the worker ~60s to flush its registry and exit on its own —
        # killing it mid-write corrupts the wine prefix.
        for _ in $(seq 1 12); do
            pgrep -f 'FarmingSimulator2025\.exe' >/dev/null 2>&1 || break
            sleep 5
        done
        kill_fs25
        log "Update applied: ${before} -> ${after}"
        return 0
    fi
    kill_fs25
    log "ERROR: update did not complete (VERSION still '${after}')"
    return 1
}

# --- main ------------------------------------------------------------------

log "Update manager started (AUTO_UPDATE=${AUTO_UPDATE:-unset}, boot=$BOOT_MODE)"

# Single instance guard.
exec 9>"$LOCK"
if ! flock -n 9; then
    log "Another update manager is already running, exiting"
    exit 0
fi

if [ "$BOOT_MODE" -eq 1 ]; then
    # Pre-supervisord run: bail fast when the game is not usable yet — the
    # install/activation helpers handle first boot after the stack is up.
    [ -f "$DEDI_EXE" ] && [ -f "$VERSION_FILE" ] || { log "boot: game not installed yet, skipping"; exit 0; }
    activated || { log "boot: not activated yet, skipping"; exit 0; }
else
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
fi

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

if [ "$BOOT_MODE" -eq 1 ]; then
    # The only thing --boot does: apply the pending patch while no FS25
    # process exists yet, on a private Xvnc display the launcher can
    # render onto (:99 — supervisord wipes /tmp/.X* for :0 later anyway).
    if [ -n "$LATEST" ] && version_lt "$INST" "$LATEST" && $AUTO_JSON && $ACTIVATED; then
        export DISPLAY=:99
        Xvnc "$DISPLAY" -depth 24 -geometry 1024x768 -SecurityTypes=None -rfbport 5999 >/dev/null 2>&1 &
        BOOT_X_PID=$!
        if wait_x && wait_prefix; then
            if run_headless_update; then
                NEW="$(installed_version)"
                write_state "$NEW" "$LATEST" false "$AUTO_JSON" "updated from $INST"
            else
                write_state "$INST" "$LATEST" true "$AUTO_JSON" "update failed"
            fi
        else
            log "ERROR: private X display / wine prefix not ready"
            write_state "$INST" "$LATEST" true "$AUTO_JSON" "boot env not ready"
        fi
        kill "$BOOT_X_PID" 2>/dev/null || true
    else
        if [ -z "$LATEST" ]; then
            write_state "${INST:-}" "" false "$AUTO_JSON" "latest check unreachable"
        elif version_lt "$INST" "$LATEST"; then
            write_state "$INST" "$LATEST" true "$AUTO_JSON" "auto update disabled or not activated"
        else
            write_state "$INST" "$LATEST" false "$AUTO_JSON"
        fi
    fi
    exit 0
fi

# Watcher mode (game running): never attempt a GUI update — the FS25
# instance mutex makes it impossible. Refresh state only.
if [ -z "$LATEST" ]; then
    write_state "${INST:-}" "" false "$AUTO_JSON" "latest check unreachable"
elif version_lt "$INST" "$LATEST"; then
    write_state "$INST" "$LATEST" true "$AUTO_JSON" "restart to update"
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
