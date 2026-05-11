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

CURRENT_STEP=0
TOTAL_STEPS=14

CONFIG_FOLDERS=(niri waybar fish zsh fastfetch mako alacritty kitty starship nvim yazi gtklock rofi scripts)

# Fedora-safe package list ONLY
readonly DNF_PACKAGES=(
  git curl wget unzip jq ffmpeg ImageMagick libnotify
  fastfetch waybar mako alacritty kitty starship
  neovim yazi zathura zathura-pdf-mupdf gtklock rofi-wayland
  polkit-gnome thunar pavucontrol
  pipewire pipewire-pulseaudio bluez bluez-tools
  gcc gcc-c++ make cmake ninja-build
)

# ==========================
# LOGGING
# ==========================

log() { echo "[$(date +'%F %T')] $*" >> "$LOG_FILE"; }
msg() { echo -e "\033[0;32m==>\033[0m $1"; log "$1"; }
warn() { echo -e "\033[1;33mWARN:\033[0m $1"; log "WARN: $1"; }
error() { echo -e "\033[0;31mERROR:\033[0m $1" >&2; log "ERROR: $1"; }

step() {
  ((CURRENT_STEP++))
  echo -e "\n\033[0;36m[Step $CURRENT_STEP/$TOTAL_STEPS] $1\033[0m"
  log "STEP: $1"
}

fatal() {
  error "$1"
  echo "Check log: $LOG_FILE"
  exit 1
}

run() {
  "$@" >> "$LOG_FILE" 2>&1 || {
    fatal "Command failed: $*"
  }
}

# ==========================
# CHECKS
# ==========================

check_fedora() {
  command -v dnf >/dev/null || fatal "Not Fedora"
  grep -qi fedora /etc/os-release || fatal "Not Fedora system"
  msg "Fedora detected"
}

check_sudo() {
  sudo -v || fatal "Need sudo"
}

check_net() {
  curl -s https://google.com >/dev/null || fatal "No internet"
}

# ==========================
# SYSTEM SETUP
# ==========================

update_system() {
  msg "Updating system..."
  run sudo dnf upgrade -y
}

install_base_tools() {
  msg "Installing base tools..."
  run sudo dnf install -y git curl wget
}

install_packages() {
  msg "Installing packages..."

  # IMPORTANT FIX:
  # Fedora sometimes fails entire transaction → we prevent silent stop
  if ! sudo dnf install -y "${DNF_PACKAGES[@]}"; then
    fatal "Package installation failed (dnf transaction error)"
  fi

  msg "Packages installed"
}

# ==========================
# COPR (SAFE)
# ==========================

enable_copr() {
  msg "Enabling COPR (non-fatal)..."

  sudo dnf install -y dnf-plugins-core >> "$LOG_FILE" 2>&1 || {
    warn "dnf-plugins-core failed"
    return 0
  }

  sudo dnf copr enable -y yalter/niri >> "$LOG_FILE" 2>&1 || {
    warn "COPR enable failed (continuing anyway)"
    return 0
  }

  msg "COPR done"
}

# ==========================
# RUST
# ==========================

setup_rust() {
  command -v rustup >/dev/null || sudo dnf install -y rustup
  rustup default stable >> "$LOG_FILE" 2>&1 || true
  msg "Rust ready"
}

install_cargo_tools() {
  command -v wallust >/dev/null || {
    msg "Installing wallust via cargo"
    cargo install wallust >> "$LOG_FILE" 2>&1 || warn "wallust failed"
  }
}

# ==========================
# OPTIONAL CHECKS (NON-FATAL)
# ==========================

check_optional() {
  rpm -q pipewire >/dev/null || warn "PipeWire missing"
  rpm -q bluez >/dev/null || warn "Bluetooth missing"
}

# ==========================
# DOTFILES
# ==========================

clone_dotfiles() {
  msg "Cloning dotfiles..."

  rm -rf "$DOTDIR"

  if ! git clone --depth=1 "$REPO_URL" "$DOTDIR" >> "$LOG_FILE" 2>&1; then
    fatal "Dotfiles clone failed"
  fi

  msg "Dotfiles cloned"
}

backup_config() {
  msg "Backing up configs..."

  mkdir -p "$BACKUP_DIR"

  for f in "${CONFIG_FOLDERS[@]}"; do
    [[ -e "$CONFIG_DIR/$f" ]] && mv "$CONFIG_DIR/$f" "$BACKUP_DIR/" 2>/dev/null || true
  done

  msg "Backup complete"
}

create_symlinks() {
  msg "Creating symlinks..."

  mkdir -p "$CONFIG_DIR"

  for f in "${CONFIG_FOLDERS[@]}"; do
    [[ -d "$DOTDIR/$f" ]] || continue

    rm -rf "$CONFIG_DIR/$f"
    ln -s "$DOTDIR/$f" "$CONFIG_DIR/$f" || warn "Failed link: $f"
  done

  msg "Symlinks created"
}

# ==========================
# THEMES (SAFE)
# ==========================

install_themes() {
  msg "Installing GTK themes..."

  tmp=$(mktemp -d)

  git clone --depth=1 https://github.com/vinceliuice/Colloid-gtk-theme "$tmp" >> "$LOG_FILE" 2>&1 || {
    warn "Theme clone failed"
    return
  }

  (cd "$tmp" && ./install.sh --libadwaita --tweaks all rimless) >> "$LOG_FILE" 2>&1 || warn "Theme install failed"

  rm -rf "$tmp"
}

install_icons() {
  msg "Installing icons..."

  tmp=$(mktemp -d)

  git clone --depth=1 https://github.com/vinceliuice/Colloid-icon-theme "$tmp" >> "$LOG_FILE" 2>&1 || {
    warn "Icon clone failed"
    return
  }

  (cd "$tmp" && ./install.sh -d "$HOME/.icons" --scheme all --bold) >> "$LOG_FILE" 2>&1 || warn "Icon install failed"

  rm -rf "$tmp"
}

# ==========================
# SHELLS
# ==========================

configure_shells() {
  sudo dnf install -y fish zsh >> "$LOG_FILE" 2>&1 || warn "Shell install failed"
  msg "Shells ready"
}

# ==========================
# VERIFY
# ==========================

verify_bins() {
  for b in niri waybar fish fastfetch mako alacritty kitty starship nvim yazi rofi; do
    command -v "$b" >/dev/null || warn "Missing: $b"
  done
}

# ==========================
# MAIN (FIXED FLOW)
# ==========================

main() {
  mkdir -p "$LOG_DIR"

  step "Checks"
  check_fedora
  check_sudo
  check_net

  step "System update"
  update_system

  step "Base tools"
  install_base_tools

  step "Packages"
  install_packages

  step "COPR"
  enable_copr

  step "Rust"
  setup_rust
  install_cargo_tools

  step "Optional checks"
  check_optional

  step "Backup"
  backup_config

  step "Dotfiles"
  clone_dotfiles

  step "Symlinks"
  create_symlinks

  step "Themes"
  install_themes
  install_icons

  step "Shells"
  configure_shells

  step "Verify"
  verify_bins

  msg "DONE"
  msg "Log: $LOG_FILE"
}

main "$@"
