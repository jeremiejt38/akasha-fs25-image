#!/bin/bash

# Copy webserver config (web UI credentials stay env-managed, baked into the
# template by init.sh on every boot).

if [ -d ~/.fs25server/drive_c/Program\ Files\ \(x86\)/Farming\ Simulator\ 2025/ ]; then
  cp "/home/container/.fs25-build/default_dedicatedServer.xml" ~/.fs25server/drive_c/Program\ Files\ \(x86\)/Farming\ Simulator\ 2025/dedicatedServer.xml
else
  echo -e "${RED}ERROR: Game is not installed?${NOCOLOR}" && exit
fi

# Copy server config — but NEVER overwrite an existing file. After the first
# boot the persistent XML belongs to the user and the Pelican Save Manager
# (map choice, save slot, gameplay settings); env vars only seed the template
# used when the file is absent.

CONFIG_DIR=~/.fs25server/drive_c/users/nobody/Documents/My\ Games/FarmingSimulator2025
DEST="$CONFIG_DIR/dedicated_server/dedicatedServerConfig.xml"

if [ -d "$CONFIG_DIR" ]; then
  if [ ! -f "$DEST" ]; then
    mkdir -p "$CONFIG_DIR/dedicated_server"
    cp "/home/container/.fs25-build/default_dedicatedServerConfig.xml" "$DEST"
    echo -e "${GREEN}Installed default dedicatedServerConfig.xml${NOCOLOR}"
  else
    echo -e "${GREEN}dedicatedServerConfig.xml exists, preserving persistent config${NOCOLOR}"
  fi

# The game port is Pelican infrastructure (allocation / relay range), not a
# player setting: always sync it from SERVER_PORT, whatever the persistent
# XML says — otherwise a re-allocation leaves the game bound to a dead port.
if [ -f "$DEST" ] && [ -n "${SERVER_PORT:-}" ]; then
  sed -i "s|<port>[0-9]\{1,5\}</port>|<port>${SERVER_PORT}</port>|" "$DEST"
fi
else
  echo -e "${RED}ERROR: Game didn't start for first time, no directories?${NOCOLOR}" && exit
fi
