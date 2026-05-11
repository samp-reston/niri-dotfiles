#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

# ==========================
# CONFIGURATION
# ==========================

readonly REPO_URL="https://github.com/samp-reston/niri-dotfiles.git"
readonly DOTDIR="${HOME}/.dotfiles-sevens"
readonly CONFIG_DIR="${HOME}/.config"
readonly BACKUP_DIR="${HOME}/.config_backup_$(date +%Y%m%d_%H%M%S)"
readonly LOG_DIR="${HOME}/.cache"
readonly LOG_FILE="${LOG_DIR}/sevens-dots-install-$(date +%Y%m%d_%H%M%S).log"

TEMP_BUILD_DIR=""

CURRENT_STEP=0
readonly TOTAL_STEPS=16

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

# Fedora base packages
readonly DNF_PACKAGES=(
  niri waybar fish fastfetch mako alacritty kitty starship neovim yazi
  zathura zathura-pdf-mupdf jetbrains-mono-fonts-all
  qt5-qtwayland qt6-qtwayland polkit-gnome ffmpeg ImageMagick unzip jq
  gtklock rofi-wayland curl libnotify
  pavucontrol thunar git rustup cargo
  base-devel gcc gcc-c++ make cmake ninja-build
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

log() { printf "[%s] %s\n" "$(date +'%F %T')" "$*" >> "${LOG_FILE}"; }

msg() { printf "${GREEN}==>${NC} %s\n" "$1"; log "$1"; }
info() { printf "${BLUE}==>${NC} %s\n" "$1"; log "$1"; }
warn() { printf "${YELLOW}[WARN]${NC} %s\n" "$1"; log "WARN: $1"; }
error() { printf "${RED}[ERROR]${NC} %s\n" "$1" >&2; log "ERROR: $1"; }

fatal() {
  error "$1"
  exit 1
}

step() {
  ((CURRENT_STEP++)) || true
  printf "\n${CYAN}[Step %d/%d]${NC} ${MAGENTA}%s${NC}\n" \
    "${CURRENT_STEP}" "${TOTAL_STEPS}" "$1"
}

# ==========================
# SYSTEM CHECKS
# ==========================

check_not_root() {
  [[ $EUID -eq 0 ]] && fatal "Do not run as root"
}

check_fedora() {
  command -v dnf >/dev/null || fatal "This requires Fedora (dnf missing)"
  grep -qi fedora /etc/os-release || fatal "Not a Fedora system"
  msg "Fedora detected"
}

check_sudo() {
  sudo -v || fatal "Need sudo access"
}

check_internet() {
  curl -s https://google.com >/dev/null || fatal "No internet"
  msg "Internet OK"
}

# ==========================
# SYSTEM UPDATE
# ==========================

update_system() {
  sudo dnf upgrade -y >> "$LOG_FILE" 2>&1 || fatal "Update failed"
  msg "System updated"
}

install_base_tools() {
  sudo dnf install -y git curl wget >> "$LOG_FILE" 2>&1
  msg "Base tools installed"
}

# ==========================
# COPR (for niri etc)
# ==========================

enable_copr() {
  sudo dnf install -y dnf-plugins-core >> "$LOG_FILE" 2>&1

  # Example COPR (adjust if needed)
  sudo dnf copr enable -y yalter/niri >> "$LOG_FILE" 2>&1 || warn "COPR enable failed"
}

# ==========================
# PACKAGES
# ==========================

install_packages() {
  info "Installing Fedora packages..."
  sudo dnf install -y "${DNF_PACKAGES[@]}" >> "$LOG_FILE" 2>&1 \
    || fatal "Package install failed"
  msg "Packages installed"
}

# ==========================
# RUST / CARGO
# ==========================

setup_rust() {
  if ! command -v rustup >/dev/null; then
    sudo dnf install -y rustup
  fi

  rustup default stable >> "$LOG_FILE" 2>&1 || true
  msg "Rust ready"
}

install_cargo_tools() {
  if ! command -v wallust >/dev/null; then
    cargo install wallust >> "$LOG_FILE" 2>&1 || warn "wallust failed"
  fi
}

# ==========================
# OPTIONAL BACKENDS CHECK
# ==========================

check_optional() {
  for pkg in "${OPTIONAL_AUDIO_PACKAGES[@]}"; do
    rpm -q "$pkg" >/dev/null || warn "Missing audio backend: $pkg"
  done

  for pkg in "${OPTIONAL_BLUETOOTH_PACKAGES[@]}"; do
    rpm -q "$pkg" >/dev/null || warn "Missing bluetooth backend: $pkg"
  done
}

# ==========================
# DOTFILES
# ==========================

clone_dotfiles() {
  [[ -d "$DOTDIR" ]] && rm -rf "$DOTDIR"

  git clone --depth=1 "$REPO_URL" "$DOTDIR" >> "$LOG_FILE" 2>&1 \
    || fatal "Clone failed"

  msg "Dotfiles cloned"
}

create_symlinks() {
  mkdir -p "$CONFIG_DIR"

  for f in "${CONFIG_FOLDERS[@]}"; do
    [[ -d "$DOTDIR/$f" ]] || continue
    rm -rf "$CONFIG_DIR/$f"
    ln -s "$DOTDIR/$f" "$CONFIG_DIR/$f"
    info "Linked $f"
  done
}

# ==========================
# BACKUP
# ==========================

backup_config() {
  mkdir -p "$BACKUP_DIR"

  for f in "${CONFIG_FOLDERS[@]}"; do
    [[ -e "$CONFIG_DIR/$f" ]] || continue
    mv "$CONFIG_DIR/$f" "$BACKUP_DIR/" 2>/dev/null || true
  done

  msg "Backup done"
}

# ==========================
# SHELL CONFIG
# ==========================

configure_shells() {
  sudo dnf install -y fish zsh

  CONFIGURE_FISH=true
  CONFIGURE_ZSH=true
}

# ==========================
# THEMES (unchanged logic)
# ==========================

install_themes() {
  info "Themes should be installed from GitHub scripts (unchanged)"
}

# ==========================
# MAIN
# ==========================

main() {
  mkdir -p "$LOG_DIR"

  step "Checks"
  check_not_root
  check_fedora
  check_sudo
  check_internet

  step "System update"
  update_system

  step "Base tools"
  install_base_tools

  step "COPR"
  enable_copr

  step "Packages"
  install_packages

  step "Rust"
  setup_rust
  install_cargo_tools

  step "Optional deps"
  check_optional

  step "Backup"
  backup_config

  step "Clone dotfiles"
  clone_dotfiles

  step "Symlinks"
  create_symlinks

  step "Shells"
  configure_shells

  msg "Done. Log: $LOG_FILE"
}

main "$@"
