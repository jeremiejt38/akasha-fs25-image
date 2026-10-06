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

# The upstream scripts export USER=nobody before creating the Wine prefix, so
# the persistent config symlink lives under users/nobody. Wine processes that
# run with another $USER write to a non-symlinked profile directory.
export WINEPREFIX USER=nobody

log() {
    echo "[$(date -Iseconds)] $1" >> "$LOG"
}

# Accepted activation writes AHC_*.dat + AHT_*.dat at the top level of the
# config dir the moment the product key is validated. That pair is sufficient:
# the dedicated server accepts Start with just those present. AVD/IDT files at
# the same level are written later by other engine paths and are NOT required —
# importantly, the dedicated server also writes its own small AVD_*.dat inside
# dedicated_server/ at every boot, which must never count as activation.
has_root_artifact() {
    find "$CONFIG_DIR" -maxdepth 1 -name "$1" 2>/dev/null | grep -q .
}

activated() {
    has_root_artifact 'AHC_*.dat' && has_root_artifact 'AHT_*.dat'
}

# Early signal: either license artifact appeared at the config root.
activation_started() {
    has_root_artifact 'AHC_*.dat' || has_root_artifact 'AHT_*.dat'
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

# Wait for the Wine prefix AND the persistent config symlink. If any Wine
# process runs before wine_symlinks.sh, it creates a real
# My Games/FarmingSimulator2025 dir in the ephemeral prefix and the symlink
# is then skipped, losing activation on every restart.
PROFILE_LINK="${WINEPREFIX}/drive_c/users/nobody/Documents/My Games/FarmingSimulator2025"
for i in $(seq 1 180); do
    [ -f "${WINEPREFIX}/system.reg" ] && [ -L "$PROFILE_LINK" ] && break
    # A real dir blocking the symlink: migrate its content then remove it.
    if [ -f "${WINEPREFIX}/system.reg" ] && [ -d "$PROFILE_LINK" ] && [ ! -L "$PROFILE_LINK" ]; then
        mkdir -p "$CONFIG_DIR"
        cp -an "$PROFILE_LINK/." "$CONFIG_DIR/" 2>/dev/null || true
        rm -rf "$PROFILE_LINK"
    fi
    if [ -f "${WINEPREFIX}/system.reg" ]; then
        USER=nobody HOME=/home/container /usr/local/bin/wine_symlinks.sh >/dev/null 2>&1 || true
    fi
    sleep 2
done
if [ ! -L "$PROFILE_LINK" ]; then
    log "ERROR: persistent config symlink not established"
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

# Inno Setup drops FarmingSimulator2025.exe early in the install. Wait until
# the installer process is actually gone before launching the game.
for i in $(seq 1 360); do
    if ! pgrep -f 'SETUP\.tmp|SETUP\.EXE|Setup\.exe' >/dev/null 2>&1; then
        break
    fi
    sleep 10
done
if pgrep -f 'SETUP\.tmp|SETUP\.EXE|Setup\.exe' >/dev/null 2>&1; then
    log "ERROR: installer still running after 60 min, giving up"
    exit 1
fi

log "Launching game for activation"
export WINEDEBUG=-all WINEDLLOVERRIDES=mscoree=d

# The product key form is rendered INSIDE the launcher window, titled
# "FarmingSimulator2025    vXXXXX" (~755x377). It appears within seconds but
# its content is not ready to receive input immediately — hence the settle
# delay before typing. A smaller "FarmingSimulator2025" dialog may also appear
# from the game exe; prefer whichever FS25 window is present.
find_activation_window() {
    local w
    w=$(xdotool search --name '^FarmingSimulator2025$' 2>/dev/null | head -1)
    if [ -n "$w" ]; then
        printf '%s' "$w"
        return
    fi
    w=$(xdotool search --name 'FarmingSimulator2025' 2>/dev/null | head -1)
    printf '%s' "$w"
}

dump_windows() {
    local id
    for id in $(xdotool search --name 'FarmingSimulator' 2>/dev/null); do
        log "  window $id: '$(xdotool getwindowname "$id" 2>/dev/null)' class=$(xdotool getwindowclassname "$id" 2>/dev/null) geo=$(xdotool getwindowgeometry "$id" 2>/dev/null | grep Geometry)"
    done
}

activate_window() {
    xdotool windowactivate --sync "$1" 2>/dev/null || true
    xdotool windowfocus --sync "$1" 2>/dev/null || true
    sleep 1
}

type_key_in() {
    local win=$1
    activate_window "$win"
    eval "$(xdotool getwindowgeometry --shell "$win" 2>/dev/null || echo 'X=0;Y=0;WIDTH=755;HEIGHT=377')"
    # Observed 755x377 launcher dialog: the product key input field sits at
    # ~64% width / ~47% height; the "Activate >" button is at ~81%/~93% and
    # "Cancel" is rightmost — do NOT click the window center or bottom edge.
    xdotool mousemove $((X + WIDTH * 64 / 100)) $((Y + HEIGHT * 47 / 100)) click 1 2>/dev/null || true
    sleep 1
    xdotool type --delay 40 "$KEY"
    sleep 1
    xdotool mousemove $((X + WIDTH * 81 / 100)) $((Y + HEIGHT * 93 / 100)) click 1 2>/dev/null || true
}

nohup wine "$GAME_EXE" >> "$LOG" 2>&1 &
GAME_PID=$!

# Try to locate the activation dialog and submit the key, up to 4 rounds.
WIN=""
for attempt in 1 2 3 4; do
    WIN=""
    for _ in $(seq 1 90); do
        WIN=$(find_activation_window)
        [ -n "$WIN" ] && break
        kill -0 "$GAME_PID" 2>/dev/null || break
        sleep 2
    done
    if [ -z "$WIN" ]; then
        log "Activation dialog not found (attempt $attempt); windows on screen:"
        dump_windows
        kill -0 "$GAME_PID" 2>/dev/null || break
        continue
    fi
    log "Activation window found (id=$WIN), waiting for form then typing key (attempt $attempt)"
    # The launcher window appears before its product key form is interactive;
    # typing too early loses the keystrokes.
    sleep 20
    type_key_in "$WIN"
    sleep 10
    # Wait up to 60s for the key to be accepted before retrying.
    for _ in $(seq 1 30); do
        activation_started && break
        sleep 2
    done
    if activation_started; then
        log "Key accepted, waiting for full license artifacts"
        break
    fi
    log "Key not accepted yet, retrying"
done

if ! activation_started; then
    log "ERROR: activation did not start (no AVD file)"
    kill "$GAME_PID" 2>/dev/null || true
    pkill -f 'FarmingSimulator2025.*\.exe' 2>/dev/null || true
    exit 1
fi

# Wait until the AHC/AHT pair lands. The game client then tries to init
# DirectX 12, fails under Wine and shows "Could not init 3D system" — dismiss
# it with its "No" button (~64%/~86% of the window) and let the crash reporter
# be cleaned up below. The dedicated server reads license state when Start is
# clicked, so it does not need a restart.
for _ in $(seq 1 150); do
    if activated; then
        log "Activation succeeded (AHC/AHT license artifacts present)"
        sleep 5
        kill "$GAME_PID" 2>/dev/null || true
        pkill -f 'FarmingSimulator2025.*\.exe' 2>/dev/null || true
        pkill -f 'GiantsCrashReporter\.exe' 2>/dev/null || true
        exit 0
    fi
    ERR=$(xdotool search --name '^FarmingSimulator2025$' 2>/dev/null | head -1)
    if [ -n "$ERR" ] && [ "$ERR" != "${WIN:-0}" ]; then
        log "Dismissing post-activation dialog (id=$ERR)"
        eval "$(xdotool getwindowgeometry --shell "$ERR" 2>/dev/null || echo 'X=0;Y=0;WIDTH=331;HEIGHT=167')"
        xdotool mousemove $((X + WIDTH * 64 / 100)) $((Y + HEIGHT * 86 / 100)) click 1 2>/dev/null || true
    fi
    sleep 2
done

log "ERROR: activation incomplete (key submitted but AHC/AHT missing)"
exit 1
