#!/bin/bash
# Headless GIANTS license activation helper for the Pelican FS25 container.
# This script runs in the background once the X server is up. It launches the
# FS25 game once through Wine, types the provided license key via xdotool and
# waits for the activation artifacts to appear in the persistent config dir.

set -u

LOG="/home/container/activation.log"
KEY_FILE="/home/container/.fs25_key"
WINEPREFIX="/home/container/.fs25server"
CONFIG_DIR="/opt/fs25/config/FarmingSimulator2025"
GAME_EXE="/opt/fs25/game/Farming Simulator 2025/FarmingSimulator2025.exe"

log() {
    echo "[$(date -Iseconds)] $1" >> "$LOG"
}

activated() {
    find "$CONFIG_DIR" "$WINEPREFIX" -name 'AVD_*.dat' -size +10c 2>/dev/null | grep -q .
}

log "Activation helper started"

# Wait for the X server.
export DISPLAY=:0
for i in $(seq 1 90); do
    if xdotool getdisplaygeometry >/dev/null 2>&1; then
        log "X server ready"
        break
    fi
    sleep 2
done
if ! xdotool getdisplaygeometry >/dev/null 2>&1; then
    log "ERROR: X server not available"
    exit 1
fi

# Skip if already activated (activation files persist in the config volume).
if activated; then
    log "License already activated, nothing to do"
    exit 0
fi

# The license key can come from a persisted file or directly from the Pelican
# egg variable GIANTS_LICENSE_KEY. If the file exists, it takes precedence.
if [ -f "$KEY_FILE" ]; then
    KEY=$(tr -d '[:space:]' < "$KEY_FILE" 2>/dev/null || true)
fi
if [ -z "${KEY:-}" ] && [ -n "${GIANTS_LICENSE_KEY:-}" ]; then
    KEY=$(printf '%s' "$GIANTS_LICENSE_KEY" | tr -d '[:space:]')
fi
if [ -z "${KEY:-}" ]; then
    log "ERROR: No license key found (expected $KEY_FILE or GIANTS_LICENSE_KEY env var)"
    exit 1
fi

# Wait for the game binary (the installer helper may still be running).
for i in $(seq 1 300); do
    [ -f "$GAME_EXE" ] && break
    sleep 5
done
if [ ! -f "$GAME_EXE" ]; then
    log "ERROR: game not installed, cannot activate"
    exit 1
fi

log "Launching game for activation"
export WINEDEBUG=-all WINEDLLOVERRIDES=mscoree=d
nohup wine "$GAME_EXE" >> "$LOG" 2>&1 &
GAME_PID=$!

# Wait for the activation window (title is "FarmingSimulator2025    vXXXXX").
WIN=""
for i in $(seq 1 90); do
    WIN=$(xdotool search --name "FarmingSimulator2025" 2>/dev/null | head -1)
    [ -n "$WIN" ] && break
    # Fallback: any window whose title contains both words.
    WIN=$(xdotool search --name "Farming Simulator" 2>/dev/null | head -1)
    [ -n "$WIN" ] && break
    sleep 2
done

if [ -z "$WIN" ]; then
    log "ERROR: FS25 activation window did not appear"
    kill "$GAME_PID" 2>/dev/null || true
    exit 1
fi

log "FS25 window found (id=$WIN), typing key"
sleep 2

activate_window() {
    xdotool windowactivate --sync "$WIN" 2>/dev/null || true
    xdotool windowfocus --sync "$WIN" 2>/dev/null || true
    sleep 1
}

activate_window

# The activation dialog centers a single input field; click its center then type.
eval "$(xdotool getwindowgeometry --shell "$WIN" 2>/dev/null || echo 'X=0;Y=0;WIDTH=800;HEIGHT=400')"
xdotool mousemove $((X + WIDTH / 2)) $((Y + HEIGHT / 2)) click 1 2>/dev/null || true
sleep 1
xdotool type "$KEY"
sleep 1
# The Activate button sits at the bottom right of the dialog.
xdotool mousemove $((X + WIDTH - 140)) $((Y + HEIGHT - 30)) click 1 2>/dev/null || xdotool key Return
sleep 5

# Dismiss any follow-up dialogs (update prompt, 3D warnings) by pressing Enter/n.
for i in $(seq 1 5); do
    ERR=$(xdotool search --name "3D" 2>/dev/null | head -1)
    if [ -n "$ERR" ]; then
        log "Dismissing 3D dialog"
        xdotool key --window "$ERR" n 2>/dev/null || xdotool key n
        sleep 2
    fi
    sleep 2
done

# Wait for activation files.
for i in $(seq 1 90); do
    if activated; then
        log "Activation succeeded (AVD file found)"
        kill "$GAME_PID" 2>/dev/null || true
        exit 0
    fi
    sleep 2
done

log "ERROR: Activation did not complete in time"
kill "$GAME_PID" 2>/dev/null || true
exit 1
