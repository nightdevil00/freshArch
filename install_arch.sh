#!/usr/bin/env bash
set -euo pipefail

# Colors
R='\033[0;31m'; G='\033[0;32m'; Y='\033[1;33m'; B='\033[0;34m'; N='\033[0m'

ask() { printf "${Y}[Y/n]${N} %s " "$1"; read -r ans; case "$ans" in [nN]*) return 1;; *) return 0;; esac; }
warn() { echo -e "${R}WARNING:${N} $1"; }
info() { echo -e "${B}INFO:${N} $1"; }
ok()   { echo -e "${G}OK:${N} $1"; }

abort() { warn "$1"; echo "Aborted."; exit 1; }

[[ $EUID -eq 0 ]] || abort "This script must be run as root."

# ==============================
# LOGGING SETUP
# ==============================
LOGFILE="/root/install_arch.log"
exec > >(tee -a "$LOGFILE") 2>&1
info "Installation log: $LOGFILE"

to_gb() { awk -v b="$1" 'BEGIN{printf "%.1fGB",b/1073741824}'; }

# ==============================
# STEP 1: SELECT MODE
# ==============================
echo "=== Select installation mode ==="
echo "  1) DualBoot  — Install alongside an existing OS"
echo "  2) Full Wipe — Erase entire disk and install fresh"
echo
read -r -p "Select mode [1/2]: " MODE
case "$MODE" in
  1|D|d|dualboot|DualBoot) MODE="dualboot" ;;
  2|F|f|full|Full|fullwipe|FullWipe) MODE="fullwipe" ;;
  *) abort "Invalid mode selection." ;;
esac
info "Mode: $([[ "$MODE" == "dualboot" ]] && echo "DualBoot" || echo "Full Wipe")"

# ==============================
# STEP 2: SELECT DISK
# ==============================
echo "=== Available disks ==="
boot_source=$(findmnt -no SOURCE /run/archiso/bootmnt 2>/dev/null || true)
exclude_disk=""
if [[ -n "$boot_source" ]]; then
  dev="$boot_source"
  while true; do
    parent=$(lsblk -dno PKNAME "$dev" 2>/dev/null | tail -n1)
    [[ -n "$parent" ]] || break
    dev="/dev/$parent"
  done
  [[ $(lsblk -dno TYPE "$dev" 2>/dev/null) == "disk" ]] && exclude_disk="$dev"
fi

disks=()
while IFS= read -r d; do
  [[ "$d" == "$exclude_disk" ]] && continue
  disks+=("$d")
done < <(lsblk -dpno NAME,TYPE | awk '$2=="disk"{print $1}' | grep -E '/dev/(sd|hd|vd|nvme|mmcblk|xv)')

[[ ${#disks[@]} -eq 0 ]] && abort "No disks found."

for i in "${!disks[@]}"; do
  d="${disks[$i]}"
  size=$(lsblk -dno SIZE "$d")
  model=$(lsblk -dno MODEL "$d" | sed 's/ *$//')
  echo "  $((i+1))) $d ($size) $model"
done

echo
read -r -p "Select disk number [1-${#disks[@]}]: " sel
sel=$((sel-1))
[[ $sel -ge 0 && $sel -lt ${#disks[@]} ]] || abort "Invalid selection."
DISK="${disks[$sel]}"
info "Selected: $DISK"

# ==============================
# STEP 3: DETECT WINDOWS + FREE SPACE (DualBoot only)
# ==============================
WIN_EFI=""
FREE_START_B=""
FREE_END_B=""
FREE_SIZE_B=""

if [[ "$MODE" == "dualboot" ]]; then
  # Detect Windows EFI
  for p in $(blkid -t TYPE=vfat -o device 2>/dev/null); do
    mp=$(mktemp -d)
    if mount -o ro "$p" "$mp" 2>/dev/null; then
      if [[ -d "$mp/EFI/Microsoft" ]]; then
        WIN_EFI="$p"
        umount "$mp" 2>/dev/null; rmdir "$mp" 2>/dev/null
        break
      fi
      umount "$mp" 2>/dev/null
    fi
    rmdir "$mp" 2>/dev/null
  done

  if [[ -n "$WIN_EFI" ]]; then
    echo; ok "Windows EFI detected on $WIN_EFI"
  else
    echo; warn "No Windows EFI partition found."
    ask "Continue anyway (may overwrite existing data)?" || abort "Cancelled."
  fi

  # Detect free space
  echo
  partprobe "$DISK" 2>/dev/null || true
  sleep 1

  FREE_INFO=$(parted -m "$DISK" unit B print free 2>/dev/null | \
    awk -F: '$NF ~ /free/ {gsub(/B/,"",$2);gsub(/B/,"",$3);gsub(/B/,"",$4); if($4+0>m+0){m=$4;s=$2;e=$3}} END{if(m>0) printf "%s %s %s",s,e,m}')
  FREE_START_B=$(echo "$FREE_INFO" | awk '{print $1}')
  FREE_END_B=$(echo "$FREE_INFO" | awk '{print $2}')
  FREE_SIZE_B=$(echo "$FREE_INFO" | awk '{print $3}')

  if [[ -z "$FREE_INFO" || "$FREE_SIZE_B" -lt $((10*1073741824)) ]]; then
    abort "No usable free space (>=10GB) detected on $DISK. Shrink a partition first."
  fi

  FREE_START_GB=$(to_gb "$FREE_START_B")
  FREE_SIZE_GB=$(to_gb "$FREE_SIZE_B")
  info "Free space: $FREE_SIZE_GB (from $FREE_START_GB)"
fi

# ==============================
# STEP 4: USER INPUT
# ==============================
echo
read -r -p "Hostname [archlinux]: " HOSTNAME
HOSTNAME=${HOSTNAME:-archlinux}

read -r -p "Username: " USERNAME
[[ -n "$USERNAME" && "$USERNAME" =~ ^[a-z_][a-z0-9_-]*$ ]] || abort "Invalid username."

read -r -s -p "Password: " PASSWORD; echo
read -r -s -p "Confirm password: " PASSWORD2; echo
[[ "$PASSWORD" == "$PASSWORD2" && -n "$PASSWORD" ]] || abort "Passwords don't match or empty."

PASSWORD_HASH=$(printf '%s' "$PASSWORD" | openssl passwd -6 -stdin)

# ==============================
# STEP 5: EXTRA USER INFO
# ==============================
echo
read -r -p "Full name (for git, optional): " FULL_NAME
read -r -p "Email address (for git, optional): " EMAIL

# Keyboard layout
echo
echo "=== Keyboard layout ==="
echo "  1) English (US)        7)  Italian"
echo "  2) English (UK)        8)  Portuguese (Brazil)"
echo "  3) German              9)  Russian"
echo "  4) French              10) Japanese"
echo "  5) French (Canada)     11) Arabic"
echo "  6) Spanish             12) Turkish"
echo "                         13) Romanian"
echo
read -r -p "Select keyboard layout [1-13] (default: 1): " kb_sel
kb_sel=${kb_sel:-1}
case "$kb_sel" in
  1)  KB_LAYOUT="us" ;;
  2)  KB_LAYOUT="uk" ;;
  3)  KB_LAYOUT="de" ;;
  4)  KB_LAYOUT="fr" ;;
  5)  KB_LAYOUT="cf" ;;
  6)  KB_LAYOUT="es" ;;
  7)  KB_LAYOUT="it" ;;
  8)  KB_LAYOUT="br-abnt2" ;;
  9)  KB_LAYOUT="ru" ;;
  10) KB_LAYOUT="jp106" ;;
  11) KB_LAYOUT="ara" ;;
  12) KB_LAYOUT="trq" ;;
  13) KB_LAYOUT="ro" ;;
  *)  warn "Invalid selection, using us."; KB_LAYOUT="us" ;;
esac
info "Keyboard layout: $KB_LAYOUT"

# Load keyboard layout on console
if [[ $(tty 2>/dev/null) == "/dev/tty"* ]]; then
  loadkeys "$KB_LAYOUT" 2>/dev/null || true
fi

# Timezone
echo
info "Detecting timezone..."
TZ_GUESS=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "UTC")
read -r -p "Timezone [$TZ_GUESS]: " TZ_INPUT
TIMEZONE="${TZ_INPUT:-$TZ_GUESS}"
info "Timezone: $TIMEZONE"

# ==============================
# STEP 6: ENCRYPTION
# ==============================
echo
ENCRYPT=false
if ask "Encrypt root partition with LUKS?"; then
  ENCRYPT=true
  info "Root will be LUKS-encrypted."
else
  info "Root will NOT be encrypted."
fi

# ==============================
# STEP 7: CONFIRM
# ==============================
echo
echo "=== Installation Summary ==="
echo "  Mode:      $([[ "$MODE" == "dualboot" ]] && echo "DualBoot" || echo "Full Wipe")"
echo "  Disk:      $DISK"
if [[ "$MODE" == "dualboot" ]]; then
  echo "  Free:      $FREE_SIZE_GB at $FREE_START_GB"
  echo "  Windows:   ${WIN_EFI:+Yes ($WIN_EFI)}${WIN_EFI:-Not detected}"
fi
echo "  Encrypt:   $ENCRYPT"
echo "  Hostname:  $HOSTNAME"
echo "  Username:  $USERNAME"
echo "  Keyboard:  $KB_LAYOUT"
echo "  Timezone:  $TIMEZONE"
echo "  Full name: ${FULL_NAME:-[skipped]}"
echo "  Email:     ${EMAIL:-[skipped]}"
echo "  Boot:      Limine (UEFI)"
echo
echo "Partitions to create:"
echo "  1) 2GB EFI (fat32, esp)"
if [[ "$MODE" == "fullwipe" ]]; then
  DISK_SIZE_B=$(lsblk -b -dno SIZE "$DISK")
  ROOT_EST_SIZE=$(( DISK_SIZE_B - 2147483648 ))
  echo "  2) $(to_gb "$ROOT_EST_SIZE") Btrfs root (rest of disk)${ENCRYPT:+ (LUKS encrypted)}"
else
  echo "  2) ${FREE_SIZE_GB} Btrfs root${ENCRYPT:+ (LUKS encrypted)}"
fi

if [[ "$MODE" == "fullwipe" ]]; then
  echo
  warn "This will ERASE ALL DATA on $DISK!"
fi
echo
ask "Proceed with installation?" || abort "Cancelled."

# ==============================
# STEP 8: PARTITION
# ==============================
echo
info "Creating partitions..."

ALIGN=$((1048576))

if [[ "$MODE" == "fullwipe" ]]; then
  # Full wipe: create fresh GPT, EFI (2GB) + root (rest)
  parted --script "$DISK" mklabel gpt
  parted --script "$DISK" mkpart primary fat32 1MiB 2GiB
  parted --script "$DISK" set 1 esp on
  parted --script "$DISK" name 1 "ARCH_EFI"
  parted --script "$DISK" mkpart primary btrfs 2GiB 100%
  parted --script "$DISK" name 2 "ARCH_ROOT"

  EFI_NUM=1
  ROOT_NUM=2
else
  # DualBoot: create partitions in free space
  LAST_PART=$(lsblk -n -o PARTN "$DISK" 2>/dev/null | grep -E '^[0-9]+$' | sort -n | tail -1)
  EFI_NUM=$(( ${LAST_PART:-0} + 1 ))
  ROOT_NUM=$(( EFI_NUM + 1 ))

  EFI_SIZE_B=$((2147483648))
  EFI_START_B=$(( (FREE_START_B + ALIGN - 1) / ALIGN * ALIGN ))
  EFI_END_B=$((EFI_START_B + EFI_SIZE_B))
  ROOT_START_B=$(( (EFI_END_B + 1 + ALIGN - 1) / ALIGN * ALIGN ))
  ROOT_END_B=$((FREE_END_B / ALIGN * ALIGN - ALIGN))

  (( ROOT_END_B > ROOT_START_B )) || abort "Not enough aligned space."

  parted --script "$DISK" mkpart primary fat32 "${EFI_START_B}B" "${EFI_END_B}B"
  parted --script "$DISK" set "$EFI_NUM" esp on
  parted --script "$DISK" name "$EFI_NUM" "ARCH_EFI"
  parted --script "$DISK" mkpart primary btrfs "${ROOT_START_B}B" "${ROOT_END_B}B"
  parted --script "$DISK" name "$ROOT_NUM" "ARCH_ROOT"
fi

partprobe "$DISK"; sync; udevadm settle; sleep 1

if [[ "$DISK" == *nvme* || "$DISK" == *mmcblk* ]]; then
  EFI_DEV="${DISK}p${EFI_NUM}"
  ROOT_DEV="${DISK}p${ROOT_NUM}"
else
  EFI_DEV="${DISK}${EFI_NUM}"
  ROOT_DEV="${DISK}${ROOT_NUM}"
fi

ok "EFI: $EFI_DEV   Root: $ROOT_DEV"

# ==============================
# STEP 9: ENCRYPTION + FILESYSTEMS
# ==============================
LUKS_UUID=""
if $ENCRYPT; then
  info "Setting up LUKS on $ROOT_DEV..."
  printf "%s" "$PASSWORD" | cryptsetup luksFormat --type luks2 --batch-mode --force-password "$ROOT_DEV" -
  printf "%s" "$PASSWORD" | cryptsetup open "$ROOT_DEV" root
  ROOT_MAPPER="/dev/mapper/root"
  LUKS_UUID=$(cryptsetup luksUUID "$ROOT_DEV")
else
  ROOT_MAPPER="$ROOT_DEV"
fi

info "Creating Btrfs filesystem on $ROOT_MAPPER..."
mkfs.btrfs "$ROOT_MAPPER"

mount "$ROOT_MAPPER" /mnt
for sub in @ @home @snapshots @log; do
  btrfs subvolume create "/mnt/$sub"
done
umount /mnt

mount -o noatime,compress=zstd,subvol=@ "$ROOT_MAPPER" /mnt
mkdir -p /mnt/{home,.snapshots,var/log,boot}
mount -o noatime,compress=zstd,subvol=@home "$ROOT_MAPPER" /mnt/home
mount -o noatime,compress=zstd,subvol=@snapshots "$ROOT_MAPPER" /mnt/.snapshots
mount -o noatime,compress=zstd,subvol=@log "$ROOT_MAPPER" /mnt/var/log

udevadm settle
wipefs -a "$EFI_DEV"
mkfs.fat -F32 "$EFI_DEV"
mount -t vfat "$EFI_DEV" /mnt/boot

ok "Filesystems created and mounted."

# Copy Windows EFI bootloader for Limine chainload entry (DualBoot only)
if [[ "$MODE" == "dualboot" && -n "$WIN_EFI" ]]; then
  [[ "$EFI_DEV" == "$WIN_EFI" ]] && abort "EFI device collision with Windows partition."
  WIN_MP=$(mktemp -d)
  if mount -o ro "$WIN_EFI" "$WIN_MP" 2>/dev/null; then
    mkdir -p /mnt/boot/EFI && cp -r "$WIN_MP/EFI/Microsoft" /mnt/boot/EFI/ 2>/dev/null && ok "Windows bootloader copied to EFI" || warn "Failed to copy Windows bootloader"
    umount "$WIN_MP"
  fi
  rmdir "$WIN_MP" 2>/dev/null
fi

# Build kernel cmdline (used later inside chroot for limine.conf)
if $ENCRYPT; then
  CMDLINE="quiet splash cryptdevice=UUID=${LUKS_UUID}:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs"
  CMDLINE_FB="quiet cryptdevice=UUID=${LUKS_UUID}:root root=/dev/mapper/root rw rootflags=subvol=@ rootfstype=btrfs"
else
  ROOT_FS_UUID=$(blkid -s UUID -o value "$ROOT_DEV")
  CMDLINE="quiet splash root=UUID=${ROOT_FS_UUID} rw rootflags=subvol=@ rootfstype=btrfs"
  CMDLINE_FB="quiet root=UUID=${ROOT_FS_UUID} rw rootflags=subvol=@ rootfstype=btrfs"
fi

# ==============================
# STEP 10: PACSTRAP (offline or online)
# ==============================
info "Installing base system..."
PACMAN_CONF="/etc/pacman.conf"

PACKAGES=(
  base base-devel linux linux-firmware
  sudo btrfs-progs git nano
  dhcpcd networkmanager limine efibootmgr binutils
  amd-ucode intel-ucode
  cryptsetup pipewire pipewire-alsa pipewire-pulse wireplumber
  sof-firmware plymouth
  zram-generator
  vim
)

OFFLINE_PACMAN_CONF=""
OFFLINE_REPO="/var/cache/offline-repo"
if [[ -d "$OFFLINE_REPO" && -f "$OFFLINE_REPO/offline.db" ]]; then
  OFFLINE_PACMAN_CONF=$(mktemp /tmp/pacman-offline-XXXXXXXX.conf)
  cat > "$OFFLINE_PACMAN_CONF" << 'PACOFF'
[options]
HoldPkg = pacman glibc
Architecture = auto
CheckSpace
ParallelDownloads = 8
SigLevel = Never
LocalFileSigLevel = Optional

[offline]
SigLevel = Never
Server = file:///var/cache/offline-repo/
PACOFF
  info "Using offline repo at $OFFLINE_REPO"
  PACMAN_CONF="$OFFLINE_PACMAN_CONF"
fi

if pacstrap -C "$PACMAN_CONF" /mnt "${PACKAGES[@]}"; then
  genfstab -U /mnt >> /mnt/etc/fstab
  ok "Base system installed."
else
  abort "pacstrap failed."
fi

if [[ -n "$OFFLINE_PACMAN_CONF" ]]; then
  mkdir -p /mnt/var/cache/offline-repo
  mount --bind "$OFFLINE_REPO" /mnt/var/cache/offline-repo
  cp "$OFFLINE_PACMAN_CONF" /mnt/etc/pacman.conf
fi

# Crypttab
if $ENCRYPT; then
  echo "root UUID=$LUKS_UUID none luks,discard" >> /mnt/etc/crypttab
fi

# ==============================
# STEP 11: CHROOT CONFIGURATION
# ==============================
info "Configuring system in chroot..."

cat > /mnt/setup.sh << 'CHROOT'
#!/usr/bin/bash
set -euo pipefail
source /pwhash.env
rm /pwhash.env

TIMEZONE="__TIMEZONE__"
HOSTNAME="__HOSTNAME__"
KB="__KB__"
USERNAME="__USERNAME__"
EFINUM="__EFINUM__"
DISK="__DISK__"
ENCRYPT="__ENCRYPT__"

# Time
ln -sf "/usr/share/zoneinfo/$TIMEZONE" /etc/localtime
hwclock --systohc

# Locale
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=en_US.UTF-8" > /etc/locale.conf

# Hostname
echo "$HOSTNAME" > /etc/hostname
cat > /etc/hosts << H
127.0.0.1 localhost
::1       localhost
127.0.1.1 $HOSTNAME.localdomain $HOSTNAME
H

# Console keymap
echo "KEYMAP=$KB" > /etc/vconsole.conf

# Root password
echo "root:$PWHASH" | chpasswd -e

# User
useradd -m -G wheel -s /bin/bash "$USERNAME"
echo "$USERNAME:$PWHASH" | chpasswd -e
sed -i '/^# %wheel ALL=(ALL:ALL) ALL$/s/^# //' /etc/sudoers

# Pacman configuration (standard online repos)
cat > /etc/pacman.conf << 'PACCONF'
[options]
HoldPkg = pacman glibc
Architecture = auto
CheckSpace
ParallelDownloads = 5
SigLevel = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
PACCONF

# mkinitcpio
sed -i 's/^MODULES=.*/MODULES=(btrfs)/' /etc/mkinitcpio.conf
sed -i 's|^BINARIES=.*|BINARIES=(/usr/bin/btrfs)|' /etc/mkinitcpio.conf

if [[ "$ENCRYPT" == "true" ]]; then
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
else
  sed -i 's/^HOOKS=.*/HOOKS=(base udev autodetect microcode modconf kms keyboard keymap block filesystems fsck)/' /etc/mkinitcpio.conf
fi

echo 'COMPRESSION="zstd"' >> /etc/mkinitcpio.conf
mkinitcpio -P

# ZRAM
cat > /etc/systemd/zram-generator.conf << Z
[zram0]
zram-size = min(ram / 2, 4096)
compression-algorithm = zstd
Z

# Limine EFI
mkdir -p /boot/EFI/limine
cp /usr/share/limine/BOOTX64.EFI /boot/EFI/limine/
efibootmgr --create --disk "$DISK" --part "$EFINUM" \
  --label "Arch Linux (Limine)" \
  --loader '\EFI\limine\BOOTX64.EFI' \
  --unicode

  efibootmgr -v

# Write limine.conf
cat > /boot/EFI/limine/limine.conf << 'LIMEOF'
timeout: 3

/Arch Linux
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    cmdline: __CMDLINE__
    module_path: boot():/initramfs-linux.img

/Arch Linux (fallback)
    protocol: linux
    kernel_path: boot():/vmlinuz-linux
    cmdline: __CMDLINE_FB__
    module_path: boot():/initramfs-linux-fallback.img
LIMEOF

if [[ -d "/boot/EFI/Microsoft" ]]; then
  cat >> /boot/EFI/limine/limine.conf << 'WEOF'

/Windows Boot Manager
    protocol: chainload
    path: boot():/EFI/Microsoft/Boot/bootmgfw.efi
WEOF
fi

#systemctl enable NetworkManager
CHROOT

sed -i "s|__TIMEZONE__|$TIMEZONE|g" /mnt/setup.sh
sed -i "s|__HOSTNAME__|$HOSTNAME|g" /mnt/setup.sh
sed -i "s|__KB__|$KB_LAYOUT|g" /mnt/setup.sh
sed -i "s|__USERNAME__|$USERNAME|g" /mnt/setup.sh
printf "PWHASH='%s'\n" "$PASSWORD_HASH" > /mnt/pwhash.env
sed -i "s|__EFINUM__|$EFI_NUM|g" /mnt/setup.sh
sed -i "s|__DISK__|$DISK|g" /mnt/setup.sh
sed -i "s|__ENCRYPT__|$ENCRYPT|g" /mnt/setup.sh
sed -i "s|__CMDLINE__|$CMDLINE|g" /mnt/setup.sh
sed -i "s|__CMDLINE_FB__|$CMDLINE_FB|g" /mnt/setup.sh

chmod +x /mnt/setup.sh

if arch-chroot /mnt /setup.sh; then
  rm /mnt/setup.sh
  ok "System configured successfully."
else
  rm -f /mnt/setup.sh
  abort "System configuration failed."
fi

# Copy log to installed system
cp "$LOGFILE" /mnt/var/log/ 2>/dev/null || true

# ==============================
# STEP 12: OMARCHY SETUP
# ==============================
if [[ -d /root/omarchy ]]; then
  info "Setting up Omarchy..."

  # Save user info for omarchy inside the omarchy dir (will be copied to user's home)
  echo "${FULL_NAME:-}" > /root/omarchy/user_full_name.txt
  echo "${EMAIL:-}" > /root/omarchy/user_email_address.txt

  # Mount the offline mirror so it's accessible in the chroot
  mkdir -p /mnt/var/cache/omarchy/mirror/offline
  mount --bind /var/cache/omarchy/mirror/offline /mnt/var/cache/omarchy/mirror/offline 2>/dev/null || warn "Omarchy offline mirror not found, continuing..."

  # Mount the packages dir so it's accessible in the chroot
  mkdir -p /mnt/opt/packages
  mount --bind /opt/packages /mnt/opt/packages 2>/dev/null || warn "Omarchy packages dir not found, continuing..."

  # No need to ask for sudo during the installation (omarchy itself cleans up)
  mkdir -p /mnt/etc/sudoers.d
  cat >/mnt/etc/sudoers.d/99-omarchy-installer <<EOF
root ALL=(ALL:ALL) NOPASSWD: ALL
%wheel ALL=(ALL:ALL) NOPASSWD: ALL
$USERNAME ALL=(ALL:ALL) NOPASSWD: ALL
EOF
  chmod 440 /mnt/etc/sudoers.d/99-omarchy-installer

  # Copy the local omarchy repo to the user's home directory
  mkdir -p /mnt/home/$USERNAME/.local/share/
  cp -r /root/omarchy /mnt/home/$USERNAME/.local/share/

  chown -R 1000:1000 /mnt/home/$USERNAME/.local/

  # Ensure all necessary scripts are executable
  find /mnt/home/$USERNAME/.local/share/omarchy -type f -path "*/bin/*" -exec chmod +x {} \;
  chmod +x /mnt/home/$USERNAME/.local/share/omarchy/boot.sh 2>/dev/null || true
  chmod +x /mnt/home/$USERNAME/.local/share/omarchy/default/waybar/indicators/screen-recording.sh 2>/dev/null || true
  chmod +x /mnt/home/$USERNAME/.local/share/omarchy/default/waybar/indicators/idle.sh 2>/dev/null || true
  chmod +x /mnt/home/$USERNAME/.local/share/omarchy/default/waybar/indicators/notification-silencing.sh 2>/dev/null || true

  # Run omarchy install inside the chroot as the user
  info "Running Omarchy installer..."
  OMARCHY_MIRROR=$(cat /root/omarchy_mirror 2>/dev/null || echo "stable")
  if HOME=/home/$USERNAME \
    arch-chroot -u $USERNAME /mnt/ \
    env OMARCHY_CHROOT_INSTALL=1 \
       OMARCHY_USER_NAME="${FULL_NAME:-}" \
       OMARCHY_USER_EMAIL="${EMAIL:-}" \
       OMARCHY_MIRROR="$OMARCHY_MIRROR" \
       USER="$USERNAME" \
       HOME="/home/$USERNAME" \
    /bin/bash -lc "source /home/$USERNAME/.local/share/omarchy/install.sh || true"; then
    ok "Omarchy installation completed."
  else
    warn "Omarchy installation reported errors, continuing..."
  fi

  # Reboot if requested by the installer
  if [[ -f /mnt/var/tmp/omarchy-install-completed ]]; then
    ok "Omarchy marked installation as complete."
  fi

  # Clean up sudoers file
  rm -f /mnt/etc/sudoers.d/99-omarchy-installer 2>/dev/null || true

  # Unmount omarchy mounts
  umount /mnt/var/cache/omarchy/mirror/offline 2>/dev/null || true
  umount /mnt/opt/packages 2>/dev/null || true
else
  warn "Omarchy directory not found in /root/, skipping omarchy setup."
fi

umount -R /mnt 2>/dev/null || true

# ==============================
# STEP 13: CLEANUP
# ==============================
echo
info "Installation complete!"
echo
echo "You can now:"
echo "  1) reboot"
echo "  2) Boot into Arch Linux from the UEFI menu"
echo
ask "Reboot now?" && reboot
