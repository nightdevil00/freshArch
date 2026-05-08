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

CORE_PACKAGES=(
  base base-devel linux linux-firmware
  sudo btrfs-progs git nano
  dhcpcd networkmanager limine efibootmgr binutils
  amd-ucode intel-ucode
  cryptsetup pipewire pipewire-alsa pipewire-pulse wireplumber
  sof-firmware plymouth
  zram-generator
  vim gum waybar hyprland sddm
  1password-beta
  1password-cli
  aalib
  abseil-cpp
  accounts-qml-module
  acl
  adwaita-cursors
  adwaita-fonts
  adwaita-icon-theme
  adwaita-icon-theme-legacy
  aether
  alacritty
  alsa-card-profiles
  alsa-lib
  alsa-topology-conf
  alsa-ucm-conf
  alsa-utils
  amd-ucode
  aom
  appstream
  aquamarine
  arch-install-scripts
  archiso
  archlinux-keyring
  argon2
  asdcontrol
  atkmm
  at-spi2-core
  attica
  attr
  audit
  autoconf
  automake
  avahi
  ayatana-ido
  base
  base-devel
  bash
  bash-completion
  bat
  binutils
  bison
  blas
  bluetui
  bluez
  bluez-libs
  bolt
  boost-libs
  breeze-icons
  brightnessctl
  brotli
  btop
  btrfs-progs
  bubblewrap
  bzip2
  c-ares
  ca-certificates
  ca-certificates-mozilla
  ca-certificates-utils
  cairo
  cairomm
  capstone
  cblas
  cdparanoia
  cdrtools
  chromium
  cifs-utils
  clang
  claude-code
  cliamp
  clucene
  compiler-rt
  containerd
  convertlit
  coreutils
  cracklib
  cryptsetup
  cups
  cups-browsed
  cups-filters
  cups-pdf
  curl
  dav1d
  db5.3
  dbus
  dbus-broker
  dbus-broker-units
  dbus-glib
  dbus-units
  dconf
  debugedit
  default-cursors
  deno
  desktop-file-utils
  device-mapper
  dhcpcd
  diffutils
  djvulibre
  dkms
  docker
  docker-buildx
  docker-compose
  dosfstools
  dotnet-host
  dotnet-runtime
  dotnet-runtime-9.0
  double-conversion
  dtc
  duktape
  dust
  e2fsprogs
  ebook-tools
  edk2-ovmf
  efibootmgr
  efivar
  eglexternalplatform
  egl-gbm
  egl-wayland
  egl-wayland2
  egl-x11
  electron39
  elephant
  elephant-bluetooth
  elephant-calc
  elephant-clipboard
  elephant-desktopapplications
  elephant-files
  elephant-menus
  elephant-providerlist
  elephant-runner
  elephant-symbols
  elephant-todo
  elephant-unicode
  elephant-websearch
  ell
  enchant
  erofs-utils
  evince
  exempi
  exfatprogs
  exiv2
  expac
  expat
  eza
  fakeroot
  fastfetch
  fcitx5
  fcitx5-gtk
  fcitx5-qt
  fd
  ffmpeg
  ffmpegthumbnailer
  fftw
  file
  filesystem
  findutils
  flac
  flex
  fmt
  fontconfig
  freeglut
  freetype2
  frei0r-plugins
  fribidi
  fuse3
  fuse-common
  fzf
  gavl
  gawk
  gc
  gcc
  gcc-libs
  gcr
  gcr-4
  gdbm
  gdk-pixbuf2
  gedit
  gettext
  gexiv2
  gfxstream
  ghostscript
  giflib
  git
  github-cli
  gjs
  glib-networking
  glib2
  glibc
  glibmm
  glm
  glslang
  glu
  glycin
  glycin-gtk4
  gmp
  gnome-autoar
  gnome-boxes
  gnome-calculator
  gnome-desktop
  gnome-desktop-4
  gnome-desktop-common
  gnome-disk-utility
  gnome-keyring
  gnome-themes-extra
  gnulib-l10n
  gnupg
  gnutls
  gobject-introspection-runtime
  gperftools
  gpgme
  gpgmepp
  gpm
  gpsd
  gpu-screen-recorder
  graphene
  graphite
  grep
  grim
  groff
  gsettings-desktop-schemas
  gsettings-system-schemas
  gsfonts
  gsm
  gspell
  gssdp
  gst-libav
  gst-plugin-gtk
  gst-plugins-bad-libs
  gst-plugins-base
  gst-plugins-base-libs
  gst-plugins-good
  gstreamer
  gtest
  gtk-layer-shell
  gtk-update-icon-cache
  gtk3
  gtk4
  gtk4-layer-shell
  gtkmm3
  gtksourceview4
  gtksourceview5
  guile
  gum
  gupnp
  gupnp-dlna
  gupnp-igd
  gvfs
  gvfs-mtp
  gvfs-nfs
  gvfs-smb
  gzip
  harfbuzz
  harfbuzz-icu
  hicolor-icon-theme
  hidapi
  highway
  hunspell
  hwdata
  hwloc
  hyphen
  hyprcursor
  hyprgraphics
  hypridle
  hyprland
  hyprland-guiutils
  hyprland-preview-share-picker
  hyprlang
  hyprlock
  hyprpicker
  hyprsunset
  hyprtoolkit
  hyprutils
  hyprwayland-scanner
  hyprwire
  iana-etc
  icu
  ijs
  imagemagick
  imath
  imlib2
  impala
  imv
  inetutils
  iniparser
  intel-gmmlib
  intel-media-driver
  intel-ucode
  inxi
  iproute2
  iptables
  iputils
  iso-codes
  iw
  iwd
  jack2
  jansson
  jbig2dec
  jbigkit
  jemalloc
  jq
  js140
  json-c
  json-glib
  jsoncpp
  kaccounts-integration
  karchive
  kbd
  kbookmarks
  kcmutils
  kcodecs
  kcolorscheme
  kcompletion
  kconfig
  kconfigwidgets
  kcoreaddons
  kcrash
  kdbusaddons
  kddockwidgets
  kdenlive
  kernel-modules-hook
  keyutils
  kfilemetadata
  kglobalaccel
  kguiaddons
  ki18n
  kiconthemes
  kio
  kirigami
  kitemmodels
  kitemviews
  kjobwidgets
  kmod
  knewstuff
  knotifications
  knotifyconfig
  kpackage
  krb5
  kservice
  ktextwidgets
  kvantum
  kvantum-qt5
  kwallet
  kwidgetsaddons
  kwindowsystem
  kxmlgui
  l-smash
  lame
  lapack
  lazydocker
  lazygit
  lcms2
  ldb
  leancrypto
  leptonica
  less
  lib32-brotli
  lib32-bzip2
  lib32-curl
  lib32-e2fsprogs
  lib32-expat
  lib32-gcc-libs
  lib32-glibc
  lib32-gmp
  lib32-gnutls
  lib32-icu
  lib32-json-c
  lib32-keyutils
  lib32-krb5
  lib32-libdrm
  lib32-libelf
  lib32-libffi
  lib32-libglvnd
  lib32-libidn2
  lib32-libldap
  lib32-libnghttp2
  lib32-libnghttp3
  lib32-libngtcp2
  lib32-libpciaccess
  lib32-libpsl
  lib32-libssh2
  lib32-libtasn1
  lib32-libunistring
  lib32-libx11
  lib32-libxau
  lib32-libxcb
  lib32-libxcrypt
  lib32-libxdmcp
  lib32-libxext
  lib32-libxml2
  lib32-libxshmfence
  lib32-libxxf86vm
  lib32-llvm-libs
  lib32-lm_sensors
  lib32-mesa
  lib32-ncurses
  lib32-nettle
  lib32-nvidia-utils
  lib32-openssl
  lib32-p11-kit
  lib32-spirv-tools
  lib32-wayland
  lib32-xz
  lib32-zlib
  lib32-zstd
  libabw
  libaccounts-glib
  libaccounts-qt
  libadwaita
  libaemu
  libaio
  libarchive
  libasan
  libass
  libassuan
  libasyncns
  libatasmart
  libatomic
  libatomic_ops
  libavc1394
  libavif
  libayatana-appindicator
  libayatana-indicator
  libb2
  libblockdev
  libblockdev-crypto
  libblockdev-fs
  libblockdev-loop
  libblockdev-mdraid
  libblockdev-nvme
  libblockdev-part
  libblockdev-smart
  libblockdev-swap
  libbluray
  libbpf
  libbs2b
  libbsd
  libburn
  libbytesize
  libcaca
  libcacard
  libcanberra
  libcap
  libcap-ng
  libcbor
  libcdio
  libcdio-paranoia
  libcdr
  libcloudproviders
  libcmis
  libcolord
  libcue
  libcups
  libcupsfilters
  libcurl-gnutls
  libdaemon
  libdatachannel
  libdatrie
  libdbusmenu-glib
  libdbusmenu-gtk3
  libdc1394
  libde265
  libdecor
  libdeflate
  libdisplay-info
  libdovi
  libdrm
  libdv
  libdvdnav
  libdvdread
  libe-book
  libebur128
  libedit
  libei
  libelf
  libepoxy
  libepubgen
  libetonyek
  libevdev
  libevent
  libexif
  libexttextcat
  libfdk-aac
  libffi
  libfontenc
  libfreeaptx
  libfreehand
  libfyaml
  libgcc
  libgcrypt
  libgedit-amtk
  libgedit-gfls
  libgedit-gtksourceview
  libgedit-tepl
  libgee
  libgfortran
  libgirepository
  libgit2
  libglvnd
  libgomp
  libgpg-error
  libgsf
  libgudev
  libgxps
  libhandy
  libheif
  libice
  libidn
  libidn2
  libiec61883
  libimobiledevice
  libimobiledevice-glue
  libinih
  libinput
  libiptcdata
  libisl
  libisoburn
  libisofs
  libixion
  libjpeg-turbo
  libjuice
  libjxl
  libksba
  liblangtag
  liblc3
  libldac
  libldap
  libliftoff
  liblqr
  liblsan
  libluv
  libmakepkg-dropins
  libmanette
  libmd
  libmm-glib
  libmnl
  libmodplug
  libmpc
  libmpdclient
  libmspub
  libmtp
  libmwaw
  libmysofa
  libnautilus-extension
  libnbd
  libndp
  libnetfilter_conntrack
  libnewt
  libnfnetlink
  libnfs
  libnftnl
  libnghttp2
  libnghttp3
  libngtcp2
  libnice
  libnl
  libnm
  libnotify
  libnsbmp
  libnsgif
  libnsl
  libnumbertext
  libnvme
  libobjc
  libodfgen
  libogg
  libopenmpt
  liborcus
  libosinfo
  libp11-kit
  libpagemaker
  libpaper
  libpcap
  libpciaccess
  libpeas
  libpgm
  libpipeline
  libpipewire
  libplacebo
  libplist
  libpng
  libportal
  libportal-gtk3
  libportal-gtk4
  libppd
  libproxy
  libpsl
  libpulse
  libpwquality
  libqalculate
  libquadmath
  libqxp
  libraqm
  libraw1394
  libreoffice-fresh
  librevenge
  librsvg
  libsamplerate
  libsasl
  libseccomp
  libsecret
  libshout
  libsigc++
  libsixel
  libslirp
  libsm
  libsndfile
  libsodium
  libsoup3
  libsoxr
  libspectre
  libsrtp
  libssh
  libssh2
  libstaroffice
  libstdc++
  libstemmer
  libsynctex
  libsysprof-capture
  libtasn1
  libtatsu
  libteam
  libthai
  libtheora
  libtiff
  libtirpc
  libtommath
  libtool
  libtraceevent
  libtracefs
  libtsan
  libubsan
  libunibreak
  libunistring
  libunwind
  liburing
  libusb
  libusbmuxd
  libutempter
  libutf8proc
  libuv
  libva
  libva-nvidia-driver
  libvdpau
  libverto
  libvirt
  libvirt-glib
  libvisio
  libvorbis
  libvpl
  libvpx
  libvterm
  libwacom
  libwbclient
  libwebp
  libwireplumber
  libwpd
  libwps
  libx11
  libxau
  libxcb
  libxcomposite
  libxcrypt
  libxcursor
  libxcvt
  libxdamage
  libxdmcp
  libxdp
  libxext
  libxfixes
  libxfont2
  libxft
  libxi
  libxinerama
  libxkbcommon
  libxkbcommon-x11
  libxkbfile
  libxml2
  libxmlb
  libxmu
  libxpresent
  libxrandr
  libxrender
  libxshmfence
  libxslt
  libxss
  libxt
  libxtst
  libxv
  libxxf86vm
  libyaml
  libyuv
  libzip
  libzmf
  licenses
  lilv
  limine
  limine-mkinitcpio-hook
  limine-snapper-sync
  linux
  linux-api-headers
  linux-firmware
  linux-firmware-amdgpu
  linux-firmware-atheros
  linux-firmware-broadcom
  linux-firmware-cirrus
  linux-firmware-intel
  linux-firmware-mediatek
  linux-firmware-nvidia
  linux-firmware-other
  linux-firmware-radeon
  linux-firmware-realtek
  linux-firmware-whence
  linux-headers
  lld
  llhttp
  llvm
  llvm-libs
  lm_sensors
  lmdb
  localsearch
  localsend
  lpsolve
  lsof
  lua
  lua-luarocks
  lua51-lpeg
  lua54
  luajit
  luarocks
  lv2
  lz4
  lzo
  m4
  mailcap
  make
  mako
  man-db
  mariadb-libs
  mbedtls
  md4c
  mdadm
  media-player-info
  mesa
  minizip
  mise
  mkinitcpio
  mkinitcpio-busybox
  mlt
  mobile-broadband-provider-info
  mpdecimal
  mpfr
  mpg123
  mpv
  msgpack-c
  mtdev
  mtools
  mujs
  muparser
  nano
  nautilus
  nautilus-python
  ncurses
  ndctl
  neon
  neovim
  nettle
  networkmanager
  nftables
  noto-fonts
  noto-fonts-cjk
  noto-fonts-emoji
  npth
  nspr
  nss
  nss-mdns
  numactl
  nvidia-open-dkms
  nvidia-utils
  obs-studio
  obsidian
  ocl-icd
  omarchy-keyring
  omarchy-nvim
  omarchy-walker
  onetbb
  oniguruma
  openal
  opencore-amr
  opencv
  openexr
  openh264
  openjpeg2
  openjph
  openssh
  openssl
  opentimelineio
  opus
  orc
  osinfo-db
  p11-kit
  pacman
  pacman-mirrorlist
  pahole
  pam
  pambase
  pamixer
  pango
  pangomm
  parted
  patch
  pciutils
  pcre
  pcre2
  pcsclite
  perl
  perl-error
  perl-mailtools
  perl-timedate
  phodav
  pinentry
  pinta
  pipewire
  pipewire-alsa
  pipewire-audio
  pipewire-pulse
  pixman
  pkgconf
  playerctl
  plocate
  plymouth
  polkit
  polkit-gnome
  poppler
  poppler-data
  poppler-glib
  poppler-qt6
  popt
  portaudio
  postgresql-libs
  power-profiles-daemon
  pps-tools
  procps-ng
  protobuf
  psmisc
  pugixml
  purpose
  python
  python-aaf2
  python-cairo
  python-certifi
  python-charset-normalizer
  python-colorama
  python-dbus
  python-fastjsonschema
  python-gobject
  python-idna
  python-lark-parser
  python-packaging
  python-poetry-core
  python-pycups
  python-pyxdg
  python-requests
  python-shtab
  python-termcolor
  python-terminaltexteffects
  python-typing_extensions
  python-urllib3
  qca-qt6
  qemu-audio-alsa
  qemu-audio-dbus
  qemu-audio-jack
  qemu-audio-oss
  qemu-audio-pa
  qemu-audio-pipewire
  qemu-audio-sdl
  qemu-audio-spice
  qemu-base
  qemu-block-curl
  qemu-block-dmg
  qemu-block-nfs
  qemu-block-ssh
  qemu-chardev-spice
  qemu-common
  qemu-desktop
  qemu-hw-display-qxl
  qemu-hw-display-virtio-gpu
  qemu-hw-display-virtio-gpu-gl
  qemu-hw-display-virtio-gpu-pci
  qemu-hw-display-virtio-gpu-pci-gl
  qemu-hw-display-virtio-gpu-pci-rutabaga
  qemu-hw-display-virtio-gpu-rutabaga
  qemu-hw-display-virtio-vga
  qemu-hw-display-virtio-vga-gl
  qemu-hw-display-virtio-vga-rutabaga
  qemu-hw-uefi-vars
  qemu-hw-usb-host
  qemu-hw-usb-redirect
  qemu-hw-usb-smartcard
  qemu-img
  qemu-system-x86
  qemu-system-x86-firmware
  qemu-ui-curses
  qemu-ui-dbus
  qemu-ui-egl-headless
  qemu-ui-gtk
  qemu-ui-opengl
  qemu-ui-sdl
  qemu-ui-spice-app
  qemu-ui-spice-core
  qemu-vhost-user-gpu
  qoi
  qpdf
  qqc2-desktop-style
  qrcodegencpp-cmake
  qt5-base
  qt5-declarative
  qt5-svg
  qt5-translations
  qt5-wayland
  qt5-x11extras
  qt6-5compat
  qt6-base
  qt6-declarative
  qt6-multimedia
  qt6-multimedia-ffmpeg
  qt6-networkauth
  qt6-positioning
  qt6-shadertools
  qt6-speech
  qt6-svg
  qt6-translations
  qt6-webchannel
  qt6-webengine
  raptor
  rasqal
  rav1e
  rdma-core
  re2
  readline
  redland
  ripgrep
  rnnoise
  rsync
  rtkit
  rubberband
  ruby
  rubygems
  runc
  rust
  rutabaga-ffi
  satty
  sbc
  sdbus-cpp
  sddm
  sdl2-compat
  sdl2_image
  sdl3
  seabios
  seatd
  sed
  serd
  shaderc
  shadow
  shared-mime-info
  signal-desktop
  signond
  signon-kwallet-extension
  signon-plugin-oauth2
  signon-ui
  simde
  slang
  slurp
  smbclient
  snapper
  snappy
  sndio
  socat
  sof-firmware
  solid
  sonnet
  sord
  sound-theme-freedesktop
  spandsp
  spdlog
  speex
  speexdsp
  spice
  spice-gtk
  spice-protocol
  spirv-tools
  spotify
  sqlite
  squashfs-tools
  sratom
  srt
  starship
  sudo
  sushi
  svt-av1
  swaybg
  swayosd
  syndication
  system-config-printer
  systemd
  systemd-libs
  systemd-sysvcompat
  taglib
  talloc
  tar
  tdb
  tesseract
  tesseract-data-eng
  tesseract-data-osd
  tevent
  texinfo
  thermald
  tinysparql
  tldr
  tmux
  tobi-try
  tomlplusplus
  totem-pl-parser
  tpm2-tss
  tree-sitter
  tree-sitter-c
  tree-sitter-cli
  tree-sitter-lua
  tree-sitter-markdown
  tree-sitter-query
  tree-sitter-vim
  tree-sitter-vimdoc
  tslib
  ttf-cascadia-code-nerd
  ttf-firacode-nerd
  ttf-hack-nerd
  ttf-ia-writer
  ttf-jetbrains-mono-nerd
  ttf-liberation
  ttf-nerd-fonts-symbols-common
  ttf-nerd-fonts-symbols-mono
  twolame
  typora
  tzdata
  tzupdate
  uchardet
  udisks2
  ufw
  ufw-docker
  unibilium
  unzip
  upower
  usage
  usbredir
  uthash
  util-linux
  util-linux-libs
  uwsm
  v4l-utils
  vapoursynth
  vde2
  verdict
  vid.stab
  vim
  vim-runtime
  virglrenderer
  virtiofsd
  visual-studio-code-bin
  vmaf
  volume_key
  vpl-gpu-rt
  vte-common
  vte3
  vulkan-icd-loader
  vulkan-intel
  vulkan-mesa-implicit-layers
  walker
  wavpack
  waybar
  wayland
  wayland-protocols
  webkit2gtk-4.1
  webp-pixbuf-loader
  webrtc-audio-processing-1
  wget
  which
  whois
  wireless-regdb
  wiremix
  wireplumber
  wl-clipboard
  woff2
  woff2-font-awesome
  wolfssl
  wpa_supplicant
  wttrbar
  x264
  x265
  xcb-imdkit
  xcb-proto
  xcb-util
  xcb-util-cursor
  xcb-util-errors
  xcb-util-image
  xcb-util-keysyms
  xcb-util-renderutil
  xcb-util-wm
  xdg-dbus-proxy
  xdg-desktop-portal
  xdg-desktop-portal-gtk
  xdg-desktop-portal-hyprland
  xdg-terminal-exec
  xdg-user-dirs
  xdg-user-dirs-gtk
  xdg-utils
  xf86-input-libinput
  xkeyboard-config
  xmlsec
  xmlstarlet
  xorg-fonts-encodings
  xorg-server
  xorg-server-common
  xorg-setxkbmap
  xorg-xauth
  xorg-xkbcomp
  xorg-xprop
  xorg-xwayland
  xorgproto
  xournalpp
  xvidcore
  xxhash
  xz
  yaru-icon-theme
  yay
  yoga
  yt-dlp
  yt-dlp-ejs
  yyjson
  zenity
  zeromq
  zimg
  zint
  zip
  zix
  zlib
  zlib-ng
  zoxide
  zram-generator
  zstd
  zxing-cpp
)

PACKAGES=("${CORE_PACKAGES[@]}")

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

if [[ -n "$OFFLINE_PACMAN_CONF" ]]; then
  mapfile -t AVAILABLE < <(pacman -Sl --config "$OFFLINE_PACMAN_CONF" offline 2>/dev/null | awk 'NR>1 {print $2}')
  if (( ${#AVAILABLE[@]} > 0 )); then
    avail_set=" ${AVAILABLE[*]} "
    FILTERED=()
    for pkg in "${PACKAGES[@]}"; do
      if [[ $avail_set == *" $pkg "* ]]; then
        FILTERED+=("$pkg")
      else
        warn "Package not in offline repo (skipping): $pkg"
      fi
    done
    PACKAGES=("${FILTERED[@]}")
    info "Installing ${#PACKAGES[@]} packages from offline repo..."
  fi
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

# Pacman configuration kept from the offline repo (copied before chroot)

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
