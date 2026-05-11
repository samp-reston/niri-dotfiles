#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# ==========================
# CONFIG
# ==========================

readonly REPO_URL="https://github.com/samp-reston/niri-dotfiles.git"
readonly DOTDIR="${HOME}/.dotfiles-sevens"
readonly CONFIG_DIR="${HOME}/.config"
readonly BACKUP_DIR="${HOME}/.config_backup_$(date +%Y%m%d_%H%M%S)"
readonly LOG_DIR="${HOME}/.cache"
readonly LOG_FILE="${LOG_DIR}/sevens-dots-install-$(date +%Y%m%d_%H%M%S).log"

TEMP_BUILD_DIR=""
CURRENT_STEP=0
readonly TOTAL_STEPS=18

declare -a INSTALL_SUMMARY=()

CONFIGURE_FISH=false
CONFIGURE_ZSH=false

SUDO_PID=""

readonly CONFIG_FOLDERS=(
  niri waybar fish zsh fastfetch mako alacritty kitty starship
  nvim yazi vicinae gtklock zathura wallust rofi scripts
)

readonly OPTIONAL_AUDIO_PACKAGES=("pipewire" "pipewire-pulseaudio")
readonly OPTIONAL_BLUETOOTH_PACKAGES=("bluez" "bluez-tools")

# Fedora packages
readonly DNF_PACKAGES=(
  git curl wget unzip jq ffmpeg ImageMagick libnotify
  fastfetch waybar mako alacritty kitty starship
  neovim yazi zathura zathura-pdf-mupdf gtklock rofi-wayland
  polkit-gnome thunar pavucontrol
  pipewire pipewire-pulseaudio bluez bluez-tools
)

# ==========================
# COLORS / LOGGING
# ==========================

readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

log() { printf "[%s] %s\n" "$(date +'%F %T')" "$*" >> "$LOG_FILE"; }
msg() { printf "${GREEN}==>${NC} %s\n" "$1"; log "$1"; }
info() { printf "${BLUE}==>${NC} %s\n" "$1"; log "$1"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; log "$1"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; log "$1"; }
fatal() { error "$1"; exit 1; }

step() {
  ((CURRENT_STEP++)) || true
  printf "\n${CYAN}[Step %d/%d]${NC} ${MAGENTA}%s${NC}\n" \
    "$CURRENT_STEP" "$TOTAL_STEPS" "$1"
}

# ==========================
# UTIL
# ==========================

retry_command() {
  local max=$1; shift
  local n=1

  until "$@"; do
    [[ $n -ge $max ]] && return 1
    warn "Retry $n/$max..."
    ((n++))
    sleep $n
  done
}

verify_binary() {
  command -v "$1" >/dev/null 2>&1
}

# ==========================
# CLEANUP
# ==========================

cleanup() {
  [[ -n "$TEMP_BUILD_DIR" && -d "$TEMP_BUILD_DIR" ]] && rm -rf "$TEMP_BUILD_DIR"
}
trap cleanup EXIT

# ==========================
# SYSTEM CHECKS
# ==========================

check_fedora() {
  command -v dnf >/dev/null || fatal "Not Fedora"
  grep -qi fedora /etc/os-release || fatal "Not Fedora"
  msg "Fedora detected"
}

check_sudo() {
  sudo -v || fatal "Need sudo"
}

check_internet() {
  curl -s https://google.com >/dev/null || fatal "No internet"
}

# ==========================
# SYSTEM SETUP
# ==========================

update_system() {
  sudo dnf upgrade -y >> "$LOG_FILE" 2>&1
}

install_base() {
  sudo dnf install -y git curl wget base-devel >> "$LOG_FILE" 2>&1
}

enable_copr() {
  sudo dnf install -y dnf-plugins-core
  sudo dnf copr enable -y yalter/niri >> "$LOG_FILE" 2>&1 || warn "COPR failed"
}

install_packages() {
  sudo dnf install -y "${DNF_PACKAGES[@]}" >> "$LOG_FILE" 2>&1
}

# ==========================
# RUST / CARGO
# ==========================

setup_rust() {
  command -v rustup >/dev/null || sudo dnf install -y rustup
  rustup default stable >> "$LOG_FILE" 2>&1 || true
}

install_cargo() {
  command -v wallust >/dev/null || cargo install wallust
}

# ==========================
# OPTIONAL CHECKS
# ==========================

check_optional() {
  for p in "${OPTIONAL_AUDIO_PACKAGES[@]}"; do
    rpm -q "$p" >/dev/null || warn "Missing audio: $p"
  done
}

# ==========================
# THEMES (RESTORED)
# ==========================

install_gtk_themes() {
  local tmp
  tmp=$(mktemp -d)

  retry_command 3 git clone --depth=1 https://github.com/vinceliuice/Colloid-gtk-theme "$tmp"

  (cd "$tmp" && ./install.sh --libadwaita --tweaks all rimless) || warn "Colloid failed"
  rm -rf "$tmp"
}

install_icons() {
  local tmp
  tmp=$(mktemp -d)

  retry_command 3 git clone --depth=1 https://github.com/vinceliuice/Colloid-icon-theme "$tmp"

  (cd "$tmp" && ./install.sh -d "$HOME/.icons" --scheme all --bold) || warn "Icons failed"
  rm -rf "$tmp"
}

# ==========================
# DOTFILES
# ==========================

clone_dotfiles() {
  rm -rf "$DOTDIR"
  git clone --depth=1 "$REPO_URL" "$DOTDIR" >> "$LOG_FILE" 2>&1
}

create_symlinks() {
  mkdir -p "$CONFIG_DIR"

  for f in "${CONFIG_FOLDERS[@]}"; do
    [[ -d "$DOTDIR/$f" ]] || continue
    rm -rf "$CONFIG_DIR/$f"
    ln -s "$DOTDIR/$f" "$CONFIG_DIR/$f"
  done
}

backup() {
  mkdir -p "$BACKUP_DIR"

  for f in "${CONFIG_FOLDERS[@]}"; do
    [[ -e "$CONFIG_DIR/$f" ]] && mv "$CONFIG_DIR/$f" "$BACKUP_DIR/"
  done
}

# ==========================
# SHELLS (RESTORED)
# ==========================

configure_shells() {
  sudo dnf install -y fish zsh

  CONFIGURE_FISH=true
  CONFIGURE_ZSH=true
}

# ==========================
# SYSTEMD (RESTORED)
# ==========================

create_services() {
  local dir="$HOME/.config/systemd/user"
  mkdir -p "$dir"

  cat > "$dir/gtklock.service" <<EOF
[Unit]
Description=GTKLock

[Service]
ExecStart=$(command -v gtklock)
Type=simple
EOF

  systemctl --user daemon-reload || true
}

# ==========================
# VERIFY BINARIES (RESTORED)
# ==========================

verify_all() {
  local bins=(niri waybar fish fastfetch mako alacritty kitty starship nvim yazi rofi)
  for b in "${bins[@]}"; do
    verify_binary "$b" || warn "Missing: $b"
  done
}

# ==========================
# MAIN
# ==========================

main() {
  mkdir -p "$LOG_DIR"

  step "Checks"
  check_fedora
  check_sudo
  check_internet

  step "Update"
  update_system

  step "Base tools"
  install_base

  step "COPR"
  enable_copr

  step "Packages"
  install_packages

  step "Rust"
  setup_rust
  install_cargo

  step "Optional"
  check_optional

  step "Backup"
  backup

  step "Dotfiles"
  clone_dotfiles

  step "Symlinks"
  create_symlinks

  step "Themes"
  install_gtk_themes
  install_icons

  step "Shells"
  configure_shells

  step "Services"
  create_services

  step "Verify"
  verify_all

  msg "Done. Log: $LOG_FILE"
}

main "$@"
