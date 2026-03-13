#!/bin/bash

set -e

PACKAGES=(fuse2 libusbmuxd libimobiledevice ifuse)
MOUNTPOINT="$HOME/iPhone15Pro"

echo "Installing packages..."
sudo pacman -S --needed "${PACKAGES[@]}"

echo "Adding user to fuse group..."
sudo gpasswd -a "$USER" fuse

echo "Creating mountpoint..."
mkdir -p "$MOUNTPOINT"

echo "Setting permissions..."
sudo chown "$USER:$USER" "$MOUNTPOINT"
chmod 700 "$MOUNTPOINT"

echo "Done!"
echo ""
echo "Select an option:"
echo "1) Reboot now"
echo "2) Log out and log back in"
echo "3) Run newgrp fuse (current session only)"
echo "4) Skip (I'll do it manually)"

read -p "Enter choice [1-4]: " choice

case $choice in
    1) sudo reboot ;;
    2) pkill -KILL -u "$USER" ;;
    3) exec newgrp fuse ;;
    4) echo "Run 'ifuse ~/iPhone15Pro' when ready" ;;
esac
