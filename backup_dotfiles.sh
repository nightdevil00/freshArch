#!/bin/bash

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="${HOME}/dotfiles_backup"
BACKUP_NAME="dotfiles_${TIMESTAMP}.tar.gz"
INSTALLED_LIST="${BACKUP_DIR}/installed_packages_${TIMESTAMP}.txt"

echo "Starting dotfiles backup..."

mkdir -p "${BACKUP_DIR}"

echo "Exporting installed packages..."
{
    echo "=== Arch Linux (pacman) ==="
    pacman -Qq 2>/dev/null || echo "pacman not available"
    echo ""
    echo "=== AUR (yay) ==="
    yay -Qq 2>/dev/null || echo "yay not available"
    echo ""
    echo "=== Flatpak ==="
    flatpak list --app 2>/dev/null || echo "flatpak not available"
    echo ""
    echo "=== Snap ==="
    snap list 2>/dev/null || echo "snap not available"
    echo ""
    echo "=== pipx ==="
    pipx list 2>/dev/null || echo "pipx not available"
    echo ""
    echo "=== NPM global packages ==="
    npm list -g --depth=0 2>/dev/null || echo "npm not available"
    echo ""
    echo "=== Cargo packages ==="
    cargo install --list 2>/dev/null | head -50 || echo "cargo not available"
} > "${INSTALLED_LIST}"

echo "Installed packages saved to: ${INSTALLED_LIST}"

TEMP_DIR="${BACKUP_DIR}/temp_${TIMESTAMP}"
mkdir -p "${TEMP_DIR}/config" "${TEMP_DIR}/local" "${TEMP_DIR}/bin" "${TEMP_DIR}/home"

echo "Copying .config (excluding discord, google-chrome, steam)..."
cp -a "${HOME}/.config/." "${TEMP_DIR}/config/"
rm -rf "${TEMP_DIR}/config/discord" "${TEMP_DIR}/config/google-chrome" "${TEMP_DIR}/config/steam" "${TEMP_DIR}/config/qBittorrent"

echo "Copying .local (excluding discord, google-chrome, steam, qBittorrent)..."
cp -a "${HOME}/.local/." "${TEMP_DIR}/local/"
rm -rf "${TEMP_DIR}/local/discord" "${TEMP_DIR}/local/google-chrome" "${TEMP_DIR}/local/steam" "${TEMP_DIR}/local/qBittorrent"

echo "Copying bin"
cp -a "${HOME}/bin/." "${TEMP_DIR}/bin/"

echo "Copying .bashrc"
cp -a "${HOME}/.bashrc" "${TEMP_DIR}/home/"

cp "${INSTALLED_LIST}" "${TEMP_DIR}/"

echo "Creating archive: ${BACKUP_NAME}"
tar -czf "${BACKUP_DIR}/${BACKUP_NAME}" -C "${TEMP_DIR}" config local bin home "$(basename ${INSTALLED_LIST})"

rm -rf "${TEMP_DIR}"

echo ""
echo "Backup complete!"
echo "Archive: ${BACKUP_DIR}/${BACKUP_NAME}"
echo "Package list: ${INSTALLED_LIST}"
echo ""
echo "To restore, run: ./restore_dotfiles.sh ${BACKUP_DIR}/${BACKUP_NAME}"