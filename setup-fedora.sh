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

# Temporary directory for builds (will be cleaned up)
TEMP_BUILD_DIR=""

# Progress tracking
CURRENT_STEP=0
readonly TOTAL_STEPS=21

# Installation summary tracking
declare -a INSTALL_SUMMARY=()

# Shell configuration choices (will be set interactively)
CONFIGURE_FISH=false
CONFIGURE_ZSH=false

# Process ID for sudo keep-alive
SUDO_PID=""

# Expected configuration folders in the repo
readonly CONFIG_FOLDERS=(
  niri waybar fish zsh fastfetch mako alacritty kitty starship
  nvim yazi vicinae gtklock zathura wallust rofi scripts
)

# Optional dependencies that waybar modules depend on
readonly OPTIONAL_AUDIO_PACKAGES=("pulseaudio" "pipewire-pulseaudio")
readonly OPTIONAL_BLUETOOTH_PACKAGES=("bluez" "bluez-tools")

# Official Fedora DNF packages
# Notes on mappings from Arch:
#   ttf-jetbrains-mono-nerd       -> jetbrains-mono-fonts (nerd variant not in fedora repos)
#   qt5-wayland / qt6-wayland     -> qt5-qtwayland / qt6-qtwayland
#   polkit-gnome                  -> DROPPED in Fedora 41; use mate-polkit instead
#   gtklock                       -> NOT in Fedora repos; handled separately
#   rofi                          -> rofi (same)
#   zathura-pdf-mupdf             -> zathura-pdf-mupdf (same, available in RPMFusion)
#   starship                      -> via COPR: atim/starship
#   yazi                          -> via COPR: lihaohong/yazi
#   imagemagick                   -> ImageMagick (capital I in Fedora)
readonly DNF_PACKAGES=(
  niri waybar fish fastfetch mako alacritty kitty neovim
  zathura zathura-pdf-mupdf jetbrains-mono-fonts
  qt5-qtwayland qt6-qtwayland ffmpeg ImageMagick unzip jq
  rofi curl libnotify mate-polkit
  git gcc make
)

# Packages to install via Cargo (no Fedora/RPMFusion equivalent)
# vicinae-bin, wallust, niri-switch, awww are AUR-only; dust and eza are available via dnf
readonly CARGO_PACKAGES=(
  "vicinae"
  "wallust"
)

# Packages available in Fedora repos (previously AUR)
readonly EXTRA_DNF_PACKAGES=(
  "dust"
  "eza"
  "pavucontrol"
  "thunar"
  "minizip"
)

# ==========================
# COLOR OUTPUT
# ==========================

readonly GREEN='\033[0;32m'
readonly BLUE='\033[0;34m'
readonly YELLOW='\033[1;33m'
readonly RED='\033[0;31m'
readonly CYAN='\033[0;36m'
readonly MAGENTA='\033[0;35m'
readonly BOLD='\033[1m'
readonly NC='\033[0m'

# ==========================
# LOGGING & OUTPUT FUNCTIONS
# ==========================

log() {
  local timestamp
  timestamp="$(date +'%Y-%m-%d %H:%M:%S')"
  printf "[%s] %s\n" "${timestamp}" "$*" >> "${LOG_FILE}" 2> /dev/null || true
}

msg() {
  printf "${GREEN}==>${NC} %s\n" "$1"
  log "INFO: $1"
}

info() {
  printf "${BLUE}==>${NC} %s\n" "$1"
  log "INFO: $1"
}

warn() {
  printf "${YELLOW}[WARNING]${NC} %s\n" "$1"
  log "WARNING: $1"
}

error() {
  printf "${RED}[ERROR]${NC} %s\n" "$1" >&2
  log "ERROR: $1"
}

fatal() {
  error "$1"
  error "Installation failed. Check log file: ${LOG_FILE}"
  exit 1
}

step() {
  ((++CURRENT_STEP)) || true
  printf "\n"
  printf "${CYAN}${BOLD}[Step %d/%d]${NC} ${MAGENTA}%s${NC}\n" "${CURRENT_STEP}" "${TOTAL_STEPS}" "$1"
  printf "${CYAN}─────────────────────────────────────────────────────────${NC}\n"
  log "STEP ${CURRENT_STEP}/${TOTAL_STEPS}: $1"
}

separator() {
  printf "\n"
  printf "${BLUE}═════════════════════════════════════════════════════════${NC}\n"
  printf "\n"
}

add_summary() {
  INSTALL_SUMMARY+=("$1")
}

# ==========================
# USAGE & HELP
# ==========================

usage() {
  cat << EOF
Usage: ${0##*/} [OPTIONS]

Sevens-Dots Installer - Automated setup for Niri window manager configuration
(Fedora edition)

OPTIONS:
  -h, --help      Display this help message and exit
  -v, --version   Display version information

DESCRIPTION:
  This script automates the installation and configuration of a complete
  Niri-based desktop environment on Fedora Linux systems.

REQUIREMENTS:
  - Fedora Linux (or compatible RHEL-based distribution with DNF)
  - Active internet connection
  - Sudo privileges
  - At least 5GB free disk space

CONFIGURATION:
  The script will clone dotfiles from:
    ${REPO_URL}

  Installation directory:
    ${DOTDIR}

  Configuration will be symlinked to:
    ${CONFIG_DIR}

LOG FILE:
  Installation logs are saved to:
    ${LOG_FILE}

NOTES:
  - This script enables RPM Fusion (free & nonfree) for additional packages.
  - Some packages (vicinae, wallust, niri-switch, awww) are not in Fedora
    repos and will be built from source via Cargo where possible.
  - gtklock is not currently available in Fedora repos; it must be built
    manually from source if required.

EXAMPLES:
  ${0##*/}              # Run interactive installation
  ${0##*/} --help       # Display this help message

REPORT BUGS:
  https://github.com/samp-reston/niri-dotfiles/issues

EOF
}

version() {
  printf "Sevens-Dots Installer v2.1 (Fedora)\n"
  printf "Fedora/DNF Port\n"
}

# ==========================
# CLEANUP FUNCTIONS
# ==========================

cleanup_temp_files() {
  if [[ -n "${TEMP_BUILD_DIR}" ]] && [[ -d "${TEMP_BUILD_DIR}" ]]; then
    info "Cleaning up temporary build directory..."
    rm -rf "${TEMP_BUILD_DIR}" 2> /dev/null || true
  fi
}

cleanup_sudo_keepalive() {
  if [[ -n "${SUDO_PID}" ]] && kill -0 "${SUDO_PID}" 2> /dev/null; then
    kill "${SUDO_PID}" 2> /dev/null || true
    wait "${SUDO_PID}" 2> /dev/null || true
  fi
}

cleanup_on_exit() {
  local exit_code=$?
  cleanup_sudo_keepalive
  cleanup_temp_files

  if [[ ${exit_code} -ne 0 ]]; then
    error "Script exited with error code: ${exit_code}"
  fi
}

cleanup_on_error() {
  local line_no=$1
  error "Error occurred on line ${line_no}"
  offer_restore
  cleanup_on_exit
}

# ==========================
# UTILITY FUNCTIONS
# ==========================

retry_command() {
  local max_attempts="$1"
  shift
  local cmd=("$@")
  local attempt=1

  while [[ ${attempt} -le ${max_attempts} ]]; do
    if "${cmd[@]}"; then
      return 0
    fi

    if [[ ${attempt} -lt ${max_attempts} ]]; then
      local wait_time=$((attempt * 2))
      warn "Command failed (attempt ${attempt}/${max_attempts}). Retrying in ${wait_time} seconds..."
      sleep "${wait_time}"
    fi
    ((attempt++)) || true
  done

  return 1
}

check_internet() {
  info "Checking internet connectivity..."

  if ! command -v curl &> /dev/null; then
    warn "curl not found, will be installed with base tools"
    return 0
  fi

  local endpoints=(
    "https://fedoraproject.org"
    "https://google.com"
    "https://cloudflare.com"
  )
  local connected=false

  for endpoint in "${endpoints[@]}"; do
    if curl -s --connect-timeout 5 --max-time 10 "${endpoint}" > /dev/null 2>&1; then
      connected=true
      break
    fi
  done

  if [[ "${connected}" == "false" ]]; then
    fatal "No internet connection. Please connect to the internet and try again."
  fi

  msg "Internet connection verified."

  info "Testing connection quality..."
  if ! curl -s --connect-timeout 2 --max-time 5 https://fedoraproject.org > /dev/null 2>&1; then
    warn "Network connection appears slow. Installation may take longer than usual."
  fi
}

check_fedora_based() {
  info "Verifying Fedora-based system..."

  if ! command -v dnf &> /dev/null; then
    fatal "This script requires dnf package manager (Fedora-based distribution)."
  fi

  local distro_name="Unknown"
  local is_fedora_based=false

  if [[ -f /etc/os-release ]]; then
    distro_name="$(grep -E '^NAME=' /etc/os-release | cut -d'"' -f2)"

    if grep -qE '^ID=fedora$' /etc/os-release ||
      grep -qE '^ID_LIKE=.*fedora.*' /etc/os-release ||
      grep -qE '^ID_LIKE=.*rhel.*' /etc/os-release ||
      [[ -f /etc/fedora-release ]]; then
      is_fedora_based=true
    fi

    if [[ "${is_fedora_based}" == "false" ]]; then
      fatal "This script is designed for Fedora-based distributions only. Detected: ${distro_name}"
    fi
  fi

  msg "Fedora-based system detected: ${distro_name}"
}

check_disk_space() {
  info "Checking available disk space..."
  local available_mb
  available_mb="$(df -P -BM "${HOME}" | tail -n 1 | awk '{print $4}' | sed 's/M//')"

  if [[ ${available_mb} -lt 5000 ]]; then
    warn "Low disk space detected: ${available_mb}MB available"
    warn "Installation requires at least 5GB free space for packages and builds"
    warn "You may encounter issues during installation"
    printf "\n"

    local reply
    read -r -p "Continue anyway? (y/N): " reply < /dev/tty
    printf "\n"

    if [[ ! "${reply}" =~ ^[Yy]$ ]]; then
      fatal "Installation cancelled by user"
    fi
  else
    msg "Sufficient disk space available: ${available_mb}MB"
  fi
}

check_not_root() {
  if [[ ${EUID} -eq 0 ]]; then
    fatal "Do not run this script as root. Run as a regular user with sudo privileges."
  fi
}

check_sudo() {
  info "Verifying sudo privileges..."
  if ! sudo -v; then
    fatal "Sudo privileges required. Please ensure you have sudo access."
  fi

  (
    while true; do
      sudo -v
      sleep 50
    done
  ) &
  SUDO_PID=$!

  msg "Sudo privileges verified."
}

check_optional_dependencies() {
  info "Checking optional dependencies for waybar modules..."

  local missing_audio=true
  local missing_bluetooth=true
  local warnings=()

  # Check for audio backend (rpm -q for Fedora)
  for pkg in "${OPTIONAL_AUDIO_PACKAGES[@]}"; do
    if rpm -q "${pkg}" &> /dev/null; then
      missing_audio=false
      break
    fi
  done

  # Check for Bluetooth backend
  for pkg in "${OPTIONAL_BLUETOOTH_PACKAGES[@]}"; do
    if rpm -q "${pkg}" &> /dev/null; then
      missing_bluetooth=false
      break
    fi
  done

  if [[ "${missing_audio}" == "true" ]] || [[ "${missing_bluetooth}" == "true" ]]; then
    printf "\n"
    warn "Missing optional dependencies detected:"
    printf "\n"

    if [[ "${missing_audio}" == "true" ]]; then
      warnings+=("Audio backend (PulseAudio/PipeWire)")
      printf "${YELLOW}⚠${NC}  ${BOLD}Audio Backend:${NC} Not detected\n"
      printf "   Waybar's audio module will not display.\n"
      printf "   Install one of: ${CYAN}pulseaudio${NC} or ${CYAN}pipewire-pulseaudio${NC}\n"
      printf "   Example: ${CYAN}sudo dnf install pipewire-pulseaudio${NC}\n"
      printf "\n"
    fi

    if [[ "${missing_bluetooth}" == "true" ]]; then
      warnings+=("Bluetooth backend (bluez)")
      printf "${YELLOW}⚠${NC}  ${BOLD}Bluetooth Backend:${NC} Not detected\n"
      printf "   Waybar's Bluetooth module will not display.\n"
      printf "   Install: ${CYAN}bluez bluez-tools${NC}\n"
      printf "   Example: ${CYAN}sudo dnf install bluez bluez-tools${NC}\n"
      printf "\n"
    fi

    printf "${BLUE}${BOLD}Note:${NC} These are workflow-dependent choices:\n"
    printf "  • Some users prefer PipeWire, others prefer PulseAudio\n"
    printf "  • Not everyone needs Bluetooth functionality\n"
    printf "  • You can install these manually later if needed\n"
    printf "  • Waybar modules may show errors on first launch until backends are installed\n"
    printf "\n"

    local reply
    read -r -p "Continue installation without these optional dependencies? (Y/n): " reply < /dev/tty
    printf "\n"

    if [[ "${reply}" =~ ^[Nn]$ ]]; then
      fatal "Installation cancelled by user. Please install required dependencies and re-run."
    fi

    warn "Waybar modules may show errors on first launch - install backends to fix"
    msg "Continuing with installation (missing: ${warnings[*]})"
  else
    msg "All optional dependencies for waybar modules are installed."
  fi
}

verify_binary() {
  local binary="$1"
  if ! command -v "${binary}" &> /dev/null; then
    error "Binary '${binary}' not found in PATH."
    return 1
  fi
  return 0
}

# ==========================
# BACKUP FUNCTIONS
# ==========================

create_backup() {
  msg "Creating backup of existing configurations..."
  mkdir -p "${BACKUP_DIR}"
  mkdir -p "${CONFIG_DIR}"

  local backed_up=0
  local symlinks_found=0

  for folder in "${CONFIG_FOLDERS[@]}"; do
    local target="${CONFIG_DIR}/${folder}"
    if [[ -e "${target}" ]] || [[ -L "${target}" ]]; then
      if [[ -L "${target}" ]]; then
        local link_target
        link_target="$(readlink "${target}")"
        warn "Symlink detected: ${folder} -> ${link_target}"
        ((++symlinks_found)) || true
        rm "${target}"
        info "Removed symlink: ${folder}"
      elif cp -rL "${target}" "${BACKUP_DIR}/" 2> /dev/null; then
        rm -rf "${target}"
        info "Backed up: ${folder}"
        ((++backed_up)) || true
      else
        warn "Failed to backup: ${folder}"
      fi
    fi
  done

  if [[ ${symlinks_found} -gt 0 ]]; then
    warn "Found ${symlinks_found} symlink(s). These were removed without backup."
    warn "If they pointed to important data, you may want to restore them manually."
  fi

  if [[ ${backed_up} -gt 0 ]]; then
    msg "Backed up ${backed_up} configuration(s) to: ${BACKUP_DIR}"
  else
    info "No existing configurations found to backup."
  fi
}

offer_restore() {
  if [[ -d "${BACKUP_DIR}" ]] && [[ -n "$(ls -A "${BACKUP_DIR}" 2> /dev/null)" ]]; then
    printf "\n"
    warn "Installation encountered an error."
    printf "${YELLOW}Your previous configurations are backed up at:${NC}\n"
    printf "  %s\n" "${BACKUP_DIR}"
    printf "\n"

    local reply
    read -r -p "Would you like to restore your backup now? (y/N): " reply < /dev/tty
    printf "\n"

    if [[ "${reply}" =~ ^[Yy]$ ]]; then
      restore_backup
    fi
  fi
}

restore_backup() {
  info "Restoring backup..."

  for folder in "${BACKUP_DIR}"/*; do
    if [[ -e "${folder}" ]]; then
      local basename
      basename="$(basename "${folder}")"
      rm -rf "${CONFIG_DIR:?}/${basename}"
      mv "${folder}" "${CONFIG_DIR}/"
      info "Restored: ${basename}"
    fi
  done

  msg "Backup restored successfully."
}

# ==========================
# PACKAGE MANAGEMENT
# ==========================

enable_rpmfusion() {
  info "Enabling RPM Fusion repositories (required for some packages)..."

  local fedora_version
  fedora_version="$(rpm -E %fedora)"

  local rpmfusion_free="https://mirrors.rpmfusion.org/free/fedora/rpmfusion-free-release-${fedora_version}.noarch.rpm"
  local rpmfusion_nonfree="https://mirrors.rpmfusion.org/nonfree/fedora/rpmfusion-nonfree-release-${fedora_version}.noarch.rpm"

  if rpm -q rpmfusion-free-release &> /dev/null && rpm -q rpmfusion-nonfree-release &> /dev/null; then
    msg "RPM Fusion repositories already enabled."
    return 0
  fi

  if retry_command 3 sudo dnf install -y "${rpmfusion_free}" "${rpmfusion_nonfree}" >> "${LOG_FILE}" 2>&1; then
    msg "RPM Fusion repositories enabled."
  else
    warn "Failed to enable RPM Fusion. Some packages (e.g. ffmpeg) may not install correctly."
  fi
}

update_system() {
  info "Updating system packages..."
  if sudo dnf upgrade -y >> "${LOG_FILE}" 2>&1; then
    msg "System updated successfully."
  else
    fatal "Failed to update system packages."
  fi
}

install_base_tools() {
  info "Installing base development tools..."
  if sudo dnf install -y git curl gcc make @development-tools >> "${LOG_FILE}" 2>&1; then
    msg "Base tools installed."
  else
    fatal "Failed to install base development tools."
  fi
}

install_dnf_packages() {
  info "Installing Fedora repository packages..."
  info "This may take several minutes..."

  if sudo dnf install -y "${DNF_PACKAGES[@]}" 2>&1 | tee -a "${LOG_FILE}"; then
    msg "Fedora packages installed successfully."
  else
    fatal "Failed to install Fedora repository packages."
  fi
}

install_copr_packages() {
  info "Installing packages via COPR (starship, yazi)..."

  local copr_packages=(
    "atim/starship:starship"
    "lihaohong/yazi:yazi"
  )

  local installed=()
  local failed=()

  for entry in "${copr_packages[@]}"; do
    local repo="${entry%%:*}"
    local pkg="${entry##*:}"

    info "Enabling COPR repo: ${repo}..."
    if ! sudo dnf copr enable -y "${repo}" >> "${LOG_FILE}" 2>&1; then
      warn "Failed to enable COPR repo: ${repo} — skipping ${pkg}"
      failed+=("${pkg}")
      continue
    fi

    info "Installing ${pkg} from COPR..."
    if sudo dnf install -y "${pkg}" >> "${LOG_FILE}" 2>&1; then
      installed+=("${pkg}")
    else
      warn "Failed to install ${pkg} from COPR repo ${repo}"
      failed+=("${pkg}")
    fi
  done

  if [[ ${#installed[@]} -gt 0 ]]; then
    msg "COPR packages installed: ${installed[*]}"
  fi
  if [[ ${#failed[@]} -gt 0 ]]; then
    warn "Failed to install via COPR: ${failed[*]}"
    warn "You may need to install these manually."
  fi
}

install_extra_dnf_packages() {
  info "Installing extra packages (dust, eza, pavucontrol, thunar)..."

  local installed=()
  local failed=()

  for pkg in "${EXTRA_DNF_PACKAGES[@]}"; do
    if sudo dnf install -y "${pkg}" >> "${LOG_FILE}" 2>&1; then
      installed+=("${pkg}")
    else
      warn "Package not found in repos: ${pkg} (may require manual install)"
      failed+=("${pkg}")
    fi
  done

  if [[ ${#installed[@]} -gt 0 ]]; then
    msg "Extra packages installed: ${installed[*]}"
  fi
  if [[ ${#failed[@]} -gt 0 ]]; then
    warn "Could not install via dnf: ${failed[*]}"
    warn "You may need to install these manually."
  fi
}

configure_rust() {
  info "Checking Rust toolchain configuration..."

  if ! command -v rustup &> /dev/null; then
    info "rustup not found, installing via upstream installer..."
    if curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y --default-toolchain stable >> "${LOG_FILE}" 2>&1; then
      # Source cargo env so it's available in this session
      # shellcheck source=/dev/null
      source "${HOME}/.cargo/env" 2> /dev/null || export PATH="${HOME}/.cargo/bin:${PATH}"
      msg "rustup installed successfully."
    else
      warn "Failed to install rustup. Cargo-based packages will be skipped."
      return 1
    fi
  else
    info "rustup already installed, setting default toolchain to stable..."
    if rustup default stable >> "${LOG_FILE}" 2>&1; then
      msg "Rust toolchain configured: stable (default)"
    else
      warn "Failed to set default Rust toolchain."
      return 1
    fi
  fi

  return 0
}

install_cargo_packages() {
  info "Installing packages via Cargo (AUR-only packages not in Fedora repos)..."

  if ! command -v cargo &> /dev/null; then
    warn "cargo not found. Skipping Cargo package installation."
    warn "Packages that will be missing: ${CARGO_PACKAGES[*]}"
    warn "Install rustup and re-run: curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh"
    return 1
  fi

  local installed=()
  local failed=()

  for pkg in "${CARGO_PACKAGES[@]}"; do
    info "Building ${pkg} via cargo (this may take a while)..."
    if cargo install "${pkg}" >> "${LOG_FILE}" 2>&1; then
      installed+=("${pkg}")
    else
      warn "Failed to build: ${pkg}"
      failed+=("${pkg}")
    fi
  done

  if [[ ${#installed[@]} -gt 0 ]]; then
    msg "Cargo packages installed: ${installed[*]}"
  fi
  if [[ ${#failed[@]} -gt 0 ]]; then
    warn "Failed to install via Cargo: ${failed[*]}"
    warn "These packages may need to be installed manually."
  fi

  # Ensure ~/.cargo/bin is in PATH for the rest of the script
  export PATH="${HOME}/.cargo/bin:${PATH}"
}

install_niri_switch() {
  # niri-switch is AUR-only; attempt cargo install
  info "Attempting to install niri-switch via cargo..."
  if command -v cargo &> /dev/null; then
    if cargo install niri-switch >> "${LOG_FILE}" 2>&1; then
      msg "niri-switch installed via cargo."
    else
      warn "niri-switch not available via cargo. You may need to build it manually."
      warn "Source: https://github.com/sodiboo/niri-switch"
    fi
  else
    warn "cargo not available; skipping niri-switch."
  fi
}

install_awww() {
  # awww-git is AUR-only; attempt cargo install
  info "Attempting to install awww via cargo..."
  if command -v cargo &> /dev/null; then
    if cargo install awww >> "${LOG_FILE}" 2>&1; then
      msg "awww installed via cargo."
    else
      warn "awww not available via cargo. You may need to build it manually."
      warn "Source: https://github.com/leonasdev/awww"
    fi
  else
    warn "cargo not available; skipping awww."
  fi
}

install_nerd_fonts() {
  # ttf-nerd-fonts-symbols is AUR-only on Arch; install via dnf on Fedora
  info "Installing Nerd Fonts symbols..."
  if sudo dnf install -y fontawesome-fonts google-noto-emoji-fonts >> "${LOG_FILE}" 2>&1; then
    msg "Nerd font fallbacks installed via dnf."
  else
    warn "Could not install nerd font packages via dnf."
    warn "For full Nerd Fonts support, consider installing manually from: https://www.nerdfonts.com"
  fi
}

install_gtklock() {
  # gtklock is not packaged for Fedora; attempt to build from source
  info "gtklock is not available in Fedora repos. Attempting build from source..."

  if ! command -v cargo &> /dev/null; then
    warn "cargo not found; skipping gtklock build."
    warn "To install gtklock manually: https://github.com/jovanlanik/gtklock"
    return 1
  fi

  local build_dir
  build_dir="$(mktemp -d)"

  # Install build dependencies
  sudo dnf install -y gtk4-devel pam-devel >> "${LOG_FILE}" 2>&1 || true

  if retry_command 2 git clone --depth=1 https://github.com/jovanlanik/gtklock "${build_dir}" >> "${LOG_FILE}" 2>&1; then
    if (cd "${build_dir}" && make >> "${LOG_FILE}" 2>&1 && sudo make install >> "${LOG_FILE}" 2>&1); then
      msg "gtklock built and installed from source."
    else
      warn "Failed to build gtklock from source."
      warn "You can try manually: https://github.com/jovanlanik/gtklock"
    fi
  else
    warn "Failed to clone gtklock repository."
  fi

  rm -rf "${build_dir}"
}

install_gtk_themes() {
  info "Installing GTK themes..."
  info "This may take several minutes..."

  local themes_dir="${HOME}/.themes"
  mkdir -p "${themes_dir}"

  local installed_themes=()
  local failed_themes=()

  if install_colloid_theme; then
    installed_themes+=("Colloid")
  else
    failed_themes+=("Colloid")
  fi

  if install_rosepine_theme; then
    installed_themes+=("Rose-Pine")
  else
    failed_themes+=("Rose-Pine")
  fi

  if install_osaka_theme; then
    installed_themes+=("Osaka")
  else
    failed_themes+=("Osaka")
  fi

  if [[ ${#installed_themes[@]} -gt 0 ]]; then
    msg "Successfully installed ${#installed_themes[@]} GTK theme(s): $(IFS=' '; echo "${installed_themes[*]}")"
  fi

  if [[ ${#failed_themes[@]} -gt 0 ]]; then
    warn "Failed to install ${#failed_themes[@]} GTK theme(s): ${failed_themes[*]}"
    warn "You can manually install these themes later if needed."
  fi

  if [[ ${#installed_themes[@]} -eq 0 ]]; then
    error "All GTK themes failed to install."
    return 1
  fi

  return 0
}

install_colloid_theme() {
  local theme_installed=false
  local themes_dir="${HOME}/.themes"

  if [[ -d "${themes_dir}/Colloid" ]] ||
    [[ -d "${themes_dir}/Colloid-Dark" ]] ||
    [[ -d "${themes_dir}/Colloid-Grey" ]] ||
    [[ -d "${themes_dir}/Colloid-Grey-Dark" ]]; then
    theme_installed=true
  fi

  if [[ "${theme_installed}" == "true" ]]; then
    msg "Colloid GTK theme is already installed. Skipping..."
    return 0
  fi

  local theme_dir
  theme_dir="$(mktemp -d)"

  info "Installing Colloid GTK theme..."
  if ! retry_command 3 git clone --depth=1 https://github.com/vinceliuice/Colloid-gtk-theme "${theme_dir}" >> "${LOG_FILE}" 2>&1; then
    rm -rf "${theme_dir}"
    warn "Failed to clone Colloid theme repository."
    return 1
  fi

  if ! (cd "${theme_dir}" && ./install.sh --libadwaita --tweaks all rimless >> "${LOG_FILE}" 2>&1); then
    rm -rf "${theme_dir}"
    warn "Failed to install Colloid theme (default variant)."
    return 1
  fi

  if ! (cd "${theme_dir}" && ./install.sh --libadwaita --theme grey --tweaks black rimless >> "${LOG_FILE}" 2>&1); then
    rm -rf "${theme_dir}"
    warn "Failed to install Colloid theme (grey-black variant)."
    return 1
  fi

  rm -rf "${theme_dir}"
  msg "Colloid GTK theme installed successfully."
  return 0
}

install_rosepine_theme() {
  local theme_installed=false
  local themes_dir="${HOME}/.themes"

  if [[ -d "${themes_dir}/Rosepine-Dark-Moon" ]] ||
    [[ -d "${themes_dir}/Rosepine-Light-Moon" ]]; then
    theme_installed=true
  fi

  if [[ "${theme_installed}" == "true" ]]; then
    msg "Rose Pine GTK theme is already installed. Skipping..."
    return 0
  fi

  local theme_dir
  theme_dir="$(mktemp -d)"

  info "Installing Rose Pine GTK theme..."
  if ! retry_command 3 git clone --depth=1 https://github.com/Fausto-Korpsvart/Rose-Pine-GTK-Theme "${theme_dir}" >> "${LOG_FILE}" 2>&1; then
    rm -rf "${theme_dir}"
    warn "Failed to clone Rose Pine theme repository."
    return 1
  fi

  if ! (cd "${theme_dir}/themes" && ./install.sh --libadwaita --tweaks moon macos >> "${LOG_FILE}" 2>&1); then
    rm -rf "${theme_dir}"
    warn "Failed to install Rose Pine theme."
    return 1
  fi

  rm -rf "${theme_dir}"
  msg "Rose Pine GTK theme installed successfully."
  return 0
}

install_osaka_theme() {
  local theme_installed=false
  local themes_dir="${HOME}/.themes"

  if [[ -d "${themes_dir}/Osaka-Dark-Solarized" ]] ||
    [[ -d "${themes_dir}/Osaka-Light-Solarized" ]]; then
    theme_installed=true
  fi

  if [[ "${theme_installed}" == "true" ]]; then
    msg "Osaka GTK theme is already installed. Skipping..."
    return 0
  fi

  local theme_dir
  theme_dir="$(mktemp -d)"

  info "Installing Osaka GTK theme..."
  if ! retry_command 3 git clone --depth=1 https://github.com/Fausto-Korpsvart/Osaka-GTK-Theme "${theme_dir}" >> "${LOG_FILE}" 2>&1; then
    rm -rf "${theme_dir}"
    warn "Failed to clone Osaka theme repository."
    return 1
  fi

  if ! (cd "${theme_dir}/themes" && ./install.sh --libadwaita --tweaks solarized macos >> "${LOG_FILE}" 2>&1); then
    rm -rf "${theme_dir}"
    warn "Failed to install Osaka theme."
    return 1
  fi

  rm -rf "${theme_dir}"
  msg "Osaka GTK theme installed successfully."
  return 0
}

install_colloid_icons() {
  local icon_dir="${HOME}/.icons"

  if [[ -d "${icon_dir}/Colloid" ]]; then
    msg "Colloid icon theme is already installed. Skipping..."
    return 0
  fi

  local icons_dir
  icons_dir="$(mktemp -d)"

  info "Installing Colloid icon theme..."
  if ! retry_command 3 git clone --depth=1 https://github.com/vinceliuice/Colloid-icon-theme "${icons_dir}" >> "${LOG_FILE}" 2>&1; then
    rm -rf "${icons_dir}"
    warn "Failed to clone Colloid icon theme repository."
    return 1
  fi

  if ! (cd "${icons_dir}" && ./install.sh -d "${HOME}/.icons" --scheme all --bold >> "${LOG_FILE}" 2>&1); then
    rm -rf "${icons_dir}"
    warn "Failed to install Colloid icon theme."
    return 1
  fi

  rm -rf "${icons_dir}"
  msg "Colloid icon theme installed successfully."
  return 0
}

install_icon_themes() {
  info "Installing icon themes..."
  local icons_dir="${HOME}/.icons"
  mkdir -p "${icons_dir}"

  local installed_icons=()
  local failed_icons=()

  if install_colloid_icons; then
    installed_icons+=("Colloid")
  else
    failed_icons+=("Colloid")
  fi

  if [[ ${#installed_icons[@]} -gt 0 ]]; then
    msg "Successfully installed ${#installed_icons[@]} icon theme(s): ${installed_icons[*]}"
  fi

  if [[ ${#failed_icons[@]} -gt 0 ]]; then
    warn "Failed to install ${#failed_icons[@]} icon theme(s): ${failed_icons[*]}"
    warn "You can manually install these icon themes later if needed."
  fi

  if [[ ${#installed_icons[@]} -eq 0 ]]; then
    error "All icon themes failed to install."
    return 1
  fi

  return 0
}

verify_all_binaries() {
  info "Verifying all required binaries are installed..."
  local missing_binaries=()

  # gtklock is excluded here because it may have been built from source
  # or intentionally skipped; it's soft-warned separately
  local binaries_to_check=(
    niri waybar fish fastfetch mako alacritty kitty starship
    nvim yazi zathura rofi
  )

  # Binaries installed via cargo - warn but don't fatal if missing
  local cargo_binaries=(
    vicinae wallust awww
  )

  for binary in "${binaries_to_check[@]}"; do
    if ! verify_binary "${binary}"; then
      missing_binaries+=("${binary}")
    fi
  done

  if [[ ${#missing_binaries[@]} -gt 0 ]]; then
    error "The following required binaries are missing:"
    printf '  - %s\n' "${missing_binaries[@]}"
    fatal "Please install missing packages manually and re-run the script."
  fi

  # Soft-check for cargo-installed binaries
  for binary in "${cargo_binaries[@]}"; do
    if ! command -v "${binary}" &> /dev/null; then
      warn "Optional binary '${binary}' not found (may need manual installation or PATH update)"
    fi
  done

  msg "All required binaries verified."
}

# ==========================
# SHELL MANAGEMENT
# ==========================

configure_shells() {
  info "Shell configuration setup..."
  printf "\n"
  printf "${BLUE}${BOLD}Which shell configuration(s) would you like to set up?${NC}\n"
  printf "\n"
  printf "${CYAN}This will install and configure the selected shell(s) with the dotfiles.${NC}\n"
  printf "\n"
  printf "  1) Fish only      - Modern, user-friendly shell with auto-suggestions\n"
  printf "  2) Zsh only       - Powerful, highly customizable shell\n"
  printf "  3) Both Fish & Zsh - Set up both shell configurations\n"
  printf "  4) Neither        - Skip shell configuration (keep current setup)\n"
  printf "\n"

  local reply
  read -r -p "Enter your choice (1-4) [default: 3]: " reply < /dev/tty
  printf "\n"

  case "${reply}" in
    1)
      CONFIGURE_FISH=true
      CONFIGURE_ZSH=false
      msg "Selected: Fish shell configuration"
      ;;
    2)
      CONFIGURE_FISH=false
      CONFIGURE_ZSH=true
      msg "Selected: Zsh shell configuration"
      ;;
    4)
      CONFIGURE_FISH=false
      CONFIGURE_ZSH=false
      msg "Selected: No shell configuration"
      info "Skipping shell setup. You can configure shells manually later."
      return 0
      ;;
    *)
      CONFIGURE_FISH=true
      CONFIGURE_ZSH=true
      msg "Selected: Both Fish and Zsh configurations"
      ;;
  esac

  local shells_to_install=()

  if [[ "${CONFIGURE_FISH}" == "true" ]] && ! verify_binary fish; then
    shells_to_install+=("fish")
  fi

  if [[ "${CONFIGURE_ZSH}" == "true" ]] && ! verify_binary zsh; then
    shells_to_install+=("zsh")
  fi

  if [[ ${#shells_to_install[@]} -gt 0 ]]; then
    info "Installing selected shell(s): ${shells_to_install[*]}"
    if sudo dnf install -y "${shells_to_install[@]}" >> "${LOG_FILE}" 2>&1; then
      msg "Shell(s) installed successfully."
    else
      warn "Failed to install some shells. They may already be installed."
    fi
  else
    info "Selected shell(s) already installed."
  fi

  local configured_shells=()
  [[ "${CONFIGURE_FISH}" == "true" ]] && configured_shells+=("Fish")
  [[ "${CONFIGURE_ZSH}" == "true" ]] && configured_shells+=("Zsh")

  if [[ ${#configured_shells[@]} -gt 0 ]]; then
    msg "Shell configuration(s) ready: ${configured_shells[*]}"
  fi

  if [[ "${CONFIGURE_ZSH}" == "true" ]]; then
    info "Configuring Zsh..."
    local zshrc="${HOME}/.zshrc"

    if [[ -f "${zshrc}" ]] && ! grep -q "source.*config.zsh" "${zshrc}"; then
      mv "${zshrc}" "${zshrc}.backup.$(date +%s)"
      info "Backed up existing .zshrc"
    fi

    cat > "${zshrc}" << EOF
# Source sevens-dots configuration
source \${HOME}/.config/zsh/config.zsh

# Prevent zsh-newuser-install wizard
zstyle :compinstall filename '${HOME}/.zshrc'
EOF
    msg "Configured .zshrc to source config.zsh"
  fi
}

set_default_shell() {
  if [[ "${CONFIGURE_FISH}" == "false" ]] && [[ "${CONFIGURE_ZSH}" == "false" ]]; then
    info "No shell configurations were set up. Skipping default shell selection."
    return 0
  fi

  info "Checking default shell..."
  local current_shell
  current_shell="$(getent passwd "${USER}" | cut -d: -f7)"
  local current_shell_name
  current_shell_name="$(basename "${current_shell}")"

  printf "\n"
  printf "${BLUE}Your current shell is:${NC} %s (%s)\n" "${current_shell_name}" "${current_shell}"
  printf "\n"
  printf "${YELLOW}Would you like to change your default shell?${NC}\n"

  local option_num=1
  declare -A shell_options

  printf "  %d) Keep current shell (%s)\n" "${option_num}" "${current_shell_name}"
  ((option_num++)) || true

  if [[ "${CONFIGURE_ZSH}" == "true" ]]; then
    shell_options[${option_num}]="zsh"
    printf "  %d) zsh   - Z Shell (powerful, highly customizable)\n" "${option_num}"
    ((option_num++)) || true
  fi

  if [[ "${CONFIGURE_FISH}" == "true" ]]; then
    shell_options[${option_num}]="fish"
    printf "  %d) fish  - Friendly Interactive Shell (user-friendly, modern)\n" "${option_num}"
    ((option_num++)) || true
  fi

  local max_option=$((option_num - 1))
  printf "\n"

  local reply
  read -r -p "Enter your choice (1-${max_option}) [default: 1]: " reply < /dev/tty
  printf "\n"

  if [[ -z "${reply}" ]] || [[ "${reply}" == "1" ]]; then
    msg "Keeping current shell: ${current_shell_name}"
    return 0
  fi

  if [[ ! "${reply}" =~ ^[0-9]+$ ]] || [[ ${reply} -lt 1 ]] || [[ ${reply} -gt ${max_option} ]]; then
    warn "Invalid selection. Keeping current shell: ${current_shell_name}"
    return 0
  fi

  local shell_name="${shell_options[${reply}]}"
  if [[ -z "${shell_name}" ]]; then
    msg "Keeping current shell: ${current_shell_name}"
    return 0
  fi

  local selected_shell
  selected_shell="$(command -v "${shell_name}")"

  if [[ -z "${selected_shell}" ]]; then
    warn "${shell_name} is not installed. Installing it now..."

    if sudo dnf install -y "${shell_name}" >> "${LOG_FILE}" 2>&1; then
      selected_shell="$(command -v "${shell_name}")"
      if [[ -z "${selected_shell}" ]]; then
        error "Failed to locate ${shell_name} after installation."
        return 1
      fi
      msg "${shell_name} installed successfully."
    else
      error "Failed to install ${shell_name}."
      return 1
    fi
  fi

  if [[ "${current_shell}" == "${selected_shell}" ]]; then
    msg "${shell_name} is already your default shell."
    return 0
  fi

  info "Changing default shell to ${shell_name}..."

  if ! grep -q "^${selected_shell}\$" /etc/shells 2> /dev/null; then
    info "Adding ${shell_name} to /etc/shells..."
    printf "%s\n" "${selected_shell}" | sudo tee -a /etc/shells >> "${LOG_FILE}" 2>&1
  fi

  if chsh -s "${selected_shell}"; then
    msg "Default shell changed to ${shell_name} successfully."
    warn "You'll need to log out and back in for this to take effect."
  else
    error "Failed to change default shell."
    info "You can manually change it later with: chsh -s ${selected_shell}"
  fi
}

# ==========================
# DOTFILES MANAGEMENT
# ==========================

clone_or_update_dotfiles() {
  if [[ -d "${DOTDIR}/.git" ]]; then
    msg "Dotfiles directory exists. Updating..."
    if ! retry_command 3 git -C "${DOTDIR}" pull --rebase >> "${LOG_FILE}" 2>&1; then
      warn "Failed to update dotfiles after retries. Removing and re-cloning..."
      rm -rf "${DOTDIR}"
      clone_dotfiles
    else
      msg "Dotfiles updated successfully."
    fi
  elif [[ -d "${DOTDIR}" ]]; then
    warn "Dotfiles directory exists but is not a git repository. Removing and re-cloning..."
    rm -rf "${DOTDIR}"
    clone_dotfiles
  else
    clone_dotfiles
  fi

  info "Updating git submodules..."
  if retry_command 3 git -C "${DOTDIR}" submodule update --init --recursive >> "${LOG_FILE}" 2>&1; then
    msg "Submodules updated."
  else
    warn "Failed to update submodules after retries. Continuing anyway..."
  fi
}

clone_dotfiles() {
  info "Cloning dotfiles repository (this may take a moment)..."
  if ! retry_command 3 git clone --depth=1 "${REPO_URL}" "${DOTDIR}" >> "${LOG_FILE}" 2>&1; then
    fatal "Failed to clone dotfiles repository after multiple attempts. Check your internet connection."
  fi

  if [[ ! -d "${DOTDIR}/.git" ]]; then
    fatal "Repository cloned but .git directory not found. Clone may be corrupted."
  fi

  msg "Dotfiles cloned successfully."
}

validate_repo_structure() {
  info "Validating repository structure..."
  local missing_folders=()

  for folder in "${CONFIG_FOLDERS[@]}"; do
    if [[ ! -d "${DOTDIR}/${folder}" ]]; then
      missing_folders+=("${folder}")
    fi
  done

  if [[ ${#missing_folders[@]} -gt 0 ]]; then
    warn "The following expected folders are missing from the repository:"
    printf '  - %s\n' "${missing_folders[@]}"
    warn "Installation will continue, but these configurations will be skipped."
  else
    msg "Repository structure validated."
  fi
}

create_symlinks() {
  msg "Creating symbolic links to ~/.config..."
  local linked=0
  local skipped=0

  for folder in "${CONFIG_FOLDERS[@]}"; do
    if [[ -d "${DOTDIR}/${folder}" ]]; then
      local target="${CONFIG_DIR}/${folder}"

      if [[ -z "${CONFIG_DIR}" ]] || [[ -z "${target}" ]]; then
        fatal "Path validation failed: CONFIG_DIR or target is empty"
      fi

      if [[ -e "${target}" ]] || [[ -L "${target}" ]]; then
        warn "Target still exists: ${folder} (removing)"
        rm -rf "${target}"
      fi

      if ln -s "${DOTDIR}/${folder}" "${target}" 2>> "${LOG_FILE}"; then
        info "Linked: ${folder}"
        ((++linked)) || true
      else
        error "Failed to link: ${folder} (check log for details)"
      fi
    else
      info "Skipping: ${folder} (not found in repository)"
      ((++skipped)) || true
    fi
  done

  msg "Created ${linked} symlink(s), skipped ${skipped}."
}

install_wallpapers() {
  if [[ -d "${DOTDIR}/wallpapers" ]]; then
    info "Installing wallpapers..."
    local wallpaper_dir="${HOME}/Pictures/Wallpapers"
    mkdir -p "${wallpaper_dir}"

    shopt -s nullglob
    local wallpapers=("${DOTDIR}/wallpapers/"*)
    shopt -u nullglob

    if [[ ${#wallpapers[@]} -gt 0 ]]; then
      if cp -r "${DOTDIR}/wallpapers/"* "${wallpaper_dir}/" 2> /dev/null; then
        msg "Wallpapers installed to: ${wallpaper_dir}"
      else
        warn "Failed to copy wallpapers."
      fi
    else
      info "No wallpapers found in repository."
    fi
  else
    info "No wallpapers directory found in repository."
  fi
}

# ==========================
# SYSTEMD SERVICE MANAGEMENT
# ==========================

create_systemd_services() {
  info "Niri handles autostart via its config file."
  info "The following services are started by niri.conf:"
  printf "  - polkit-gnome-authentication-agent\n"
  printf "  - awww-daemon\n"
  printf "  - waybar\n"
  printf "  - vicinae server\n"
  printf "\n"
  info "Creating gtklock service for manual/idle trigger only..."

  local service_dir="${HOME}/.config/systemd/user"
  mkdir -p "${service_dir}"
  create_gtklock_service "${service_dir}"

  systemctl --user daemon-reload >> "${LOG_FILE}" 2>&1 || warn "Failed to reload systemd daemon."

  printf "\n"
  info "gtklock service has been created but NOT enabled by default."
  info "To manually lock your screen: systemctl --user start gtklock"
  info "To enable autostart on login: systemctl --user enable gtklock"
  printf "\n"

  msg "Systemd services configured."
}

create_gtklock_service() {
  local service_dir="$1"

  if ! verify_binary gtklock; then
    warn "gtklock binary not found, skipping service creation"
    warn "Install gtklock manually from: https://github.com/jovanlanik/gtklock"
    return
  fi

  local gtklock_bin
  gtklock_bin="$(command -v gtklock)"

  cat > "${service_dir}/gtklock.service" << EOF
[Unit]
Description=GTKLock Screen Locker
Documentation=man:gtklock(1)

[Service]
Type=simple
ExecStart=${gtklock_bin}
Restart=no
EOF

  info "Created: gtklock.service (manual trigger only)"
  info "Note: gtklock will NOT autostart. Trigger it via 'systemctl --user start gtklock'"
}

# ==========================
# MAIN INSTALLATION FLOW
# ==========================

print_header() {
  printf "\n"
  printf "${GREEN}${BOLD}"
  cat << "EOF"
════════════════════════════════════════════════════════════
  SEVENS-DOTS - Installation Script v2.1 (Fedora Edition)
  Automated setup for your Niri window manager configuration
════════════════════════════════════════════════════════════
EOF
  printf "${NC}"
  printf "\n"
  printf "Repository: ${BLUE}%s${NC}\n" "${REPO_URL}"
  printf "Log file:   ${BLUE}%s${NC}\n" "${LOG_FILE}"
  printf "\n"
  printf "${YELLOW}Note:${NC} This is the Fedora port. Some AUR-only packages will be\n"
  printf "      built from source via Cargo where possible.\n"
  printf "\n"
}

print_summary() {
  separator
  printf "${GREEN}${BOLD}"
  cat << "EOF"
════════════════════════════════════════════════════════════
  INSTALLATION COMPLETED SUCCESSFULLY!
  Your sevens-dots configuration has been installed
════════════════════════════════════════════════════════════
EOF
  printf "${NC}\n"

  if [[ ${#INSTALL_SUMMARY[@]} -gt 0 ]]; then
    printf "\n"
    printf "${CYAN}${BOLD}Installation Summary:${NC}\n"
    printf "${CYAN}────────────────────${NC}\n"
    for item in "${INSTALL_SUMMARY[@]}"; do
      printf "  ${GREEN}✓${NC} %s\n" "${item}"
    done
  fi

  separator
  printf "${MAGENTA}${BOLD}Next Steps:${NC}\n"
  printf "  1. Log out of your current session\n"
  printf "  2. Select 'Niri' from your display manager\n"
  printf "  3. Log in to start using your new setup\n"
  printf "\n"
  printf "${BLUE}${BOLD}Important Notes:${NC}\n"
  printf "  • Services are auto-started by niri.conf, not systemd\n"
  printf "  • awww-daemon, waybar, vicinae, and polkit start automatically\n"
  printf "  • gtklock can be triggered manually or via idle timeout\n"
  printf "  • Cargo-installed binaries are in ~/.cargo/bin — ensure this is in your PATH\n"
  printf "\n"

  if [[ -d "${BACKUP_DIR}" ]] && [[ -n "$(ls -A "${BACKUP_DIR}" 2> /dev/null)" ]]; then
    printf "${YELLOW}${BOLD}Backup Information:${NC}\n"
    printf "  Your previous configurations are backed up at:\n"
    printf "  ${CYAN}%s${NC}\n" "${BACKUP_DIR}"
    printf "\n"

    local reply
    read -r -p "Would you like to remove the backup directory? (y/N): " reply < /dev/tty
    printf "\n"

    if [[ "${reply}" =~ ^[Yy]$ ]]; then
      rm -rf "${BACKUP_DIR}"
      msg "Backup directory removed."
    else
      info "Backup kept for your reference."
    fi
    printf "\n"
  fi

  printf "${BLUE}${BOLD}Troubleshooting:${NC}\n"
  printf "  If you encounter any issues, check the log file:\n"
  printf "  ${CYAN}%s${NC}\n" "${LOG_FILE}"
  separator
}

main() {
  mkdir -p "${LOG_DIR}"

  print_header

  step "Pre-flight System Checks"
  check_not_root
  check_fedora_based
  check_disk_space
  check_sudo
  check_internet
  add_summary "System validated and prerequisites checked"

  step "Enabling RPM Fusion Repositories"
  enable_rpmfusion
  add_summary "RPM Fusion (free + nonfree) enabled"

  step "Checking Optional Dependencies"
  check_optional_dependencies
  add_summary "Optional dependencies checked (audio/Bluetooth backends)"

  step "System Update"
  update_system
  add_summary "System packages updated"

  step "Installing Base Development Tools"
  install_base_tools
  add_summary "Base development tools installed (git, gcc, make, curl)"

  step "Configuring Rust Toolchain"
  configure_rust || warn "Proceeding without Rust toolchain - Cargo packages will be skipped"
  add_summary "Rust toolchain configured"

  step "Installing Fedora Repository Packages"
  install_dnf_packages
  add_summary "Fedora packages installed (niri, waybar, fish, etc.)"

  step "Installing COPR Packages (starship, yazi)"
  install_copr_packages
  add_summary "COPR packages installed (starship, yazi)"

  step "Installing Extra DNF Packages"
  install_extra_dnf_packages
  add_summary "Extra packages installed (dust, eza, pavucontrol, thunar)"

  step "Installing Cargo Packages (vicinae, wallust)"
  install_cargo_packages
  install_niri_switch
  install_awww
  add_summary "Cargo packages installed (vicinae, wallust, niri-switch, awww)"

  step "Installing Nerd Fonts"
  install_nerd_fonts
  add_summary "Nerd font fallbacks installed"

  step "Installing gtklock (from source)"
  install_gtklock || warn "gtklock skipped - install manually if needed"
  add_summary "gtklock build attempted"

  step "Installing GTK Themes"
  install_gtk_themes
  add_summary "GTK themes installed (Colloid, Rose-Pine, Osaka)"

  step "Installing Icon Themes"
  install_icon_themes
  add_summary "Icon themes installed (Colloid icons)"

  step "Verifying Installed Binaries"
  verify_all_binaries
  add_summary "All required binaries verified"

  step "Selecting Shell Configurations"
  configure_shells
  add_summary "Shell configuration(s) selected and installed"

  step "Setting Default Shell"
  set_default_shell
  add_summary "Default shell configured"

  step "Creating Configuration Backup"
  create_backup
  add_summary "Existing configurations backed up to ${BACKUP_DIR}"

  step "Cloning Dotfiles Repository"
  clone_or_update_dotfiles
  add_summary "Dotfiles repository cloned from ${REPO_URL}"

  step "Validating Repository Structure"
  validate_repo_structure
  add_summary "Repository structure validated"

  step "Creating Symbolic Links"
  create_symlinks
  add_summary "Configuration symlinks created in ~/.config"

  step "Installing Wallpapers"
  install_wallpapers
  add_summary "Wallpapers installed to ~/Pictures/Wallpapers"

  step "Configuring System Services"
  create_systemd_services
  add_summary "Systemd services configured"

  print_summary
}

# ==========================
# ARGUMENT PARSING
# ==========================

parse_arguments() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -h | --help)
        usage
        exit 0
        ;;
      -v | --version)
        version
        exit 0
        ;;
      *)
        error "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
    shift
  done
}

# ==========================
# ERROR HANDLING & EXECUTION
# ==========================

trap 'cleanup_on_error ${LINENO}' ERR
trap 'cleanup_on_exit' EXIT INT TERM

parse_arguments "$@"
main
