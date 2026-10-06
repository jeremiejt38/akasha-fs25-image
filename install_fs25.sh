#!/bin/bash
# Headless FS25 installer for the Pelican container.
#
# Waits for Xvnc and the Wine prefix (created by the upstream autostart flow),
# prepares the GIANTS installer files dropped in /opt/fs25/installer, then runs
# the Inno Setup installer silently through Wine. Game files land in
# /opt/fs25/game (a persistent Pelican volume path).
#
# Supported installer layouts in /opt/fs25/installer:
#   - the official *_ESD.img UDF image downloaded from eshop.giants-software.com
#     (extracted with xorriso)
#   - already-extracted SETUP.EXE + SETUP_*.BIN disk slices
#
# Inno Setup looks for slices named like "setup-1a.bin" while the GIANTS image
# ships "SETUP_1A.BIN"; hardlinks with the expected naming are created before
# launching the installer.

set -u

LOG="/home/container/install.log"
INSTALL_DIR="/opt/fs25/installer"
GAME_DIR="/opt/fs25/game/Farming Simulator 2025"
GAME_EXE="${GAME_DIR}/dedicatedServer.exe"
WINEPREFIX="${HOME}/.fs25server"

export DISPLAY=:0
export WINEPREFIX
export WINEARCH=win64
export WINEDEBUG=-all
export WINEDLLOVERRIDES=mscoree=d
# Match the upstream Wine profile (wine_init.sh exports USER=nobody; the
# persistent config symlink lives under users/nobody).
export USER=nobody

log() {
    echo "[$(date -Iseconds)] $1" >> "$LOG"
}

log "Install helper started"

# Already installed? Nothing to do.
if [ -f "$GAME_EXE" ]; then
    log "FS25 already installed, skipping"
    exit 0
fi

# Wait for the X server.
for _ in $(seq 1 90); do
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

# Wait for the Wine prefix created by the upstream prepare_start.sh.
for _ in $(seq 1 90); do
    if [ -f "${WINEPREFIX}/system.reg" ]; then
        log "Wine prefix ready"
        break
    fi
    sleep 2
done
if [ ! -f "${WINEPREFIX}/system.reg" ]; then
    log "Wine prefix missing, creating it"
    . /usr/local/bin/wine_init.sh
fi

# The persistent config symlink must exist BEFORE any Wine process runs, or
# Wine creates a real My Games/FarmingSimulator2025 directory in the ephemeral
# prefix and wine_symlinks.sh then refuses to replace it.
PROFILE_LINK="${WINEPREFIX}/drive_c/users/nobody/Documents/My Games/FarmingSimulator2025"
CONFIG_DIR="/opt/fs25/config/FarmingSimulator2025"
for _ in $(seq 1 120); do
    [ -L "$PROFILE_LINK" ] && break
    # A real directory blocks the symlink: if it only holds files that belong
    # in the persistent config dir, migrate them and remove it.
    if [ -d "$PROFILE_LINK" ] && [ ! -L "$PROFILE_LINK" ]; then
        mkdir -p "$CONFIG_DIR"
        cp -an "$PROFILE_LINK/." "$CONFIG_DIR/" 2>/dev/null || true
        rm -rf "$PROFILE_LINK"
    fi
    USER=nobody HOME=/home/container /usr/local/bin/wine_symlinks.sh >/dev/null 2>&1 || true
    sleep 2
done
if [ ! -L "$PROFILE_LINK" ]; then
    log "ERROR: could not establish persistent config symlink"
    exit 1
fi
log "Persistent config symlink in place"

# Extract the official *_ESD.img image if that is what the customer uploaded.
IMG=$(find "$INSTALL_DIR" -maxdepth 1 -iname '*.img' | head -1)
if [ -n "$IMG" ] && [ ! -f "$INSTALL_DIR/SETUP.EXE" ] && [ ! -f "$INSTALL_DIR/Setup.exe" ]; then
    log "Extracting installer image $(basename "$IMG")"
    mkdir -p "$INSTALL_DIR/extracted"
    if xorriso -osirrox on -indev "$IMG" -extract / "$INSTALL_DIR/extracted" >>"$LOG" 2>&1; then
        cp -al "$INSTALL_DIR/extracted/." "$INSTALL_DIR/" 2>/dev/null || cp -a "$INSTALL_DIR/extracted/." "$INSTALL_DIR/"
        rm -rf "$INSTALL_DIR/extracted"
    else
        log "ERROR: failed to extract installer image"
        exit 1
    fi
fi

# Create the slice names Inno Setup actually looks for (setup-1a.bin).
for f in "$INSTALL_DIR"/SETUP_*.BIN "$INSTALL_DIR"/Setup_*.bin; do
    [ -e "$f" ] || continue
    base="$(basename "$f")"
    want="$(echo "$base" | tr 'A-Z_' 'a-z-')"
    [ -e "$INSTALL_DIR/$want" ] || ln "$f" "$INSTALL_DIR/$want" 2>/dev/null || cp "$f" "$INSTALL_DIR/$want"
done

# Pick the installer executable.
if [ -f "$INSTALL_DIR/Setup.exe" ]; then
    INSTALLER="$INSTALL_DIR/Setup.exe"
elif [ -f "$INSTALL_DIR/SETUP.EXE" ]; then
    INSTALLER="$INSTALL_DIR/SETUP.EXE"
elif [ -f "$INSTALL_DIR/FarmingSimulator2025.exe" ]; then
    INSTALLER="$INSTALL_DIR/FarmingSimulator2025.exe"
else
    log "No installer found in $INSTALL_DIR, nothing to do"
    exit 0
fi

log "Running installer: $(basename "$INSTALLER")"
wine "$INSTALLER" /SILENT /NOCANCEL /NOICONS >>"$LOG" 2>&1

if [ -f "$GAME_EXE" ]; then
    log "Installation completed"
else
    log "ERROR: installer finished but $GAME_EXE is missing"
    exit 1
fi

# The autostart flow already ran at boot and gave up because the game was not
# installed yet. Now that it is, bring up the dedicated server web admin (and
# the game itself for AUTOSTART_SERVER=true) without requiring a restart.
case "${AUTOSTART_SERVER:-}" in
    true|1|web_only)
        if ! pgrep -f 'dedicatedServer\.exe' >/dev/null 2>&1; then
            log "Starting dedicated server web admin"
            nohup /usr/local/bin/start_fs25.sh >>"$LOG" 2>&1 &
        fi
        if [[ "${AUTOSTART_SERVER}" == "true" || "${AUTOSTART_SERVER}" == "1" ]]; then
            log "AUTOSTART_SERVER=${AUTOSTART_SERVER}: requesting game start"
            sleep 45
            nohup node /usr/local/bin/start_game.mjs >>"$LOG" 2>&1 &
        fi
        ;;
esac

exit 0
