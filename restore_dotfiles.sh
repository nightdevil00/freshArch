#!/bin/bash

set -e

if [ -z "$1" ]; then
    echo "Usage: $0 <backup_archive.tar.gz>"
    echo ""
    echo "Example: $0 ~/dotfiles_backup/dotfiles_20240313_123456.tar.gz"
    exit 1
fi

BACKUP_FILE="$1"

if [ ! -f "$BACKUP_FILE" ]; then
    echo "Error: Backup file not found: $BACKUP_FILE"
    exit 1
fi

echo "Restoring dotfiles from: ${BACKUP_FILE}"
echo ""

TEMP_DIR=$(mktemp -d)
trap "rm -rf ${TEMP_DIR}" EXIT

echo "Extracting archive..."
tar -xzf "${BACKUP_FILE}" -C "${TEMP_DIR}"

echo ""
read -p "This will overwrite existing .config, .local and bin files. Continue? (y/n): " confirm
if [ "$confirm" != "y" ]; then
    echo "Aborted."
    exit 0
fi

echo ""
echo "Restoring .config..."
rm -rf "${HOME}/.config_backup_$(date +%s)" 2>/dev/null || true
mv "${HOME}/.config" "${HOME}/.config_backup_$(date +%s)" 2>/dev/null || true
cp -r "${TEMP_DIR}/config" "${HOME}/.config"

echo "Restoring .local..."
rm -rf "${HOME}/.local_backup_$(date +%s)" 2>/dev/null || true
mv "${HOME}/.local" "${HOME}/.local_backup_$(date +%s)" 2>/dev/null || true
cp -r "${TEMP_DIR}/local" "${HOME}/.local"

echo "Restoring bin..."
rm -rf "${HOME}/bin_backup_$(date +%s)" 2>/dev/null || true
mv "${HOME}/bin" "${HOME}/bin_backup_$(date +%s)" 2>/dev/null || true
mkdir -p "${HOME}/bin"
cp -r "${TEMP_DIR}/bin/." "${HOME}/bin/"

echo "Restoring .bashrc..."
if [ -f "${TEMP_DIR}/home/.bashrc" ]; then
    cp -f "${TEMP_DIR}/home/.bashrc" "${HOME}/.bashrc"
fi

echo ""
echo "Restore complete!"
echo "Old config backed up to: ${HOME}/.config_backup_*"
echo "Old local backed up to: ${HOME}/.local_backup_*"
echo "Old bin backed up to: ${HOME}/bin_backup_*"
echo ""
echo " sourcing .bashrc..."
source "${HOME}/.bashrc"

if [ -f "${TEMP_DIR}/installed_packages_*.txt" ]; then
    PACKAGE_LIST=$(ls "${TEMP_DIR}/installed_packages_"*.txt 2>/dev/null | head -1)
    if [ -n "$PACKAGE_LIST" ]; then
        echo "Installed packages list found at: ${PACKAGE_LIST}"
        echo ""
        cat "${PACKAGE_LIST}"
    fi
fi