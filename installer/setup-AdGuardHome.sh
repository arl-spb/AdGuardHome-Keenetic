#!/bin/sh
# setup-AdGuardHome.sh - Installer for AdGuard Home on KeeneticOS
# Repo: https://github.com/arl-spb/AdGuardHome-Keenetic
# Usage: ./setup-AdGuardHome.sh {install|update|uninstall|status}

# === LOGGING ===
LOG="/tmp/ag-setup.log"
: > "$LOG"

log() { echo "$1" | tee -a "$LOG"; }
warn() { log "WARN: $1"; }
die() { log "FATAL: $1"; exit 1; }

# === CONFIG ===
REPO="arl-spb/AdGuardHome-Keenetic"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH/installer"

AGH_DIR="/opt/etc/AdGuardHome"
AGH_BIN="$AGH_DIR/AdGuardHome"
CONF="$AGH_DIR/ag-keenetic.conf"
INIT="/opt/etc/init.d/S99adguardhome"
HOOK="/opt/etc/ndm/netfilter.d/99-adguard-dns.sh"
POLICY_NAME="adguard-clients"

# === UTILITY: ASK YES/NO ===
ask() {
  printf "%s [y/N]: " "$1"
  read answer < /dev/tty
  if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    return 0
  else
    return 1
  fi
}

# === UTILITY: DOWNLOAD FILE ===
get_file() {
  url="$1"
  out="$2"
  if [ "$DOWNLOADER" = "curl" ]; then
    curl -kfsSL -o "$out" -A "Mozilla/5.0" "$url" 2>/dev/null
  else
    wget -qO "$out" --no-check-certificate "$url" 2>/dev/null
  fi
  if [ -s "$out" ]; then
    return 0
  else
    return 1
  fi
}
# === ARCHITECTURE DETECTION (Keenetic only) ===
get_arch() {
  arch=$(uname -m)
  case "$arch" in
    aarch64|arm64)
      ARCH_MAP="linux_arm64"
      ;;
    mipsel)
      ARCH_MAP="linux_mipsle_softfloat"
      ;;
    armv7l)
      ARCH_MAP="linux_armv7"
      log "NOTE: ARMv7 support is experimental on Keenetic"
      ;;
    *)
      die "Unsupported for Keenetic: $arch
This script supports only:
  * aarch64 (ARM64) - Giga, Peak, Hero, Ultra, Skipper
  * mipsel (MIPS LE) - Omni, Lite, Start, Air, City
  * armv7l (ARMv7) - experimental"
      ;;
  esac
  log "Architecture: $arch -> $ARCH_MAP"
}

# === TOOL CHECK: curl or wget ===
check_tools() {
  if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
    log "Using: curl"
  else
    if command -v wget >/dev/null 2>&1; then
      DOWNLOADER="wget"
      log "Using: wget"
    else
      die "No downloader found. Install: opkg install curl"
    fi
  fi
}

# === STATUS COMMAND ===
do_status() {
  log "=== STATUS ==="
  
  # Binary
  if [ -x "$AGH_BIN" ]; then
    ver=$("$AGH_BIN" --version 2>/dev/null | awk '{print $NF}')
    log "Binary: OK ($ver)"
  else
    log "Binary: MISSING"
  fi
  
  # Service
  if pgrep -f AdGuardHome >/dev/null 2>&1; then
    log "Service: RUNNING"
  else
    log "Service: STOPPED"
  fi
  
  # Config
  if [ -f "$CONF" ]; then
    log "Config: OK"
  else
    log "Config: MISSING"
  fi
  
  # Init script
  if [ -x "$INIT" ]; then
    log "Init: OK"
  else
    log "Init: MISSING"
  fi
  
  # Hook
  if [ -x "$HOOK" ]; then
    log "Hook: OK"
  else
    log "Hook: MISSING"
  fi
  
  # Policy
  if ndmc -c "show ip policy" 2>/dev/null | grep -q "description = $POLICY_NAME"; then
    log "Policy: EXISTS"
  else
    log "Policy: MISSING"
  fi
  
  log "============"
}
# === OPKG CONFLICT CHECK ===
check_opkg() {
  if opkg list-installed 2>/dev/null | grep -q "adguardhome-go"; then
    warn "Entware package 'adguardhome-go' detected."
    warn "'opkg upgrade' will overwrite your AdGuard Home binary."
    printf "Action: [H]old pkg | [R]emove pkg | [C]ancel: "
    read action
    case "$action" in
      h|H)
        opkg hold adguardhome-go 2>/dev/null
        log "Package HELD."
        ;;
      r|R)
        opkg remove adguardhome-go 2>/dev/null
        log "Package REMOVED."
        ;;
      *)
        log "Cancelled."
        exit 0
        ;;
    esac
  fi
}

# === DEPLOY COMPONENTS ===
deploy() {
  mkdir -p "$AGH_DIR" "$(dirname "$INIT")" "$(dirname "$HOOK")"

  # Config
  if [ ! -f "$CONF" ]; then
    get_file "$RAW_BASE/ag-keenetic.conf" "$CONF" 2>/dev/null
    if [ $? -ne 0 ]; then
      printf 'AG_LISTEN_IP="127.0.0.1"\nAG_LISTEN_PORT="5354"\nAG_POLICY_NAME="adguard-clients"\n' > "$CONF"
    fi
    chmod 644 "$CONF"
    log "Created: $CONF"
  else
    if ask "Replace $CONF?"; then
      get_file "$RAW_BASE/ag-keenetic.conf" "$CONF"
      chmod 644 "$CONF"
      log "Updated: $CONF"
    else
      log "Kept: $CONF"
    fi
  fi

  # Init script
  if ask "Replace $INIT?"; then
    get_file "$RAW_BASE/S99adguardhome" "$INIT"
    chmod +x "$INIT"
    log "Updated: $INIT"
  else
    log "Kept: $INIT"
  fi

  # Hook
  if ask "Replace $HOOK?"; then
    get_file "$RAW_BASE/99-adguard-dns.sh" "$HOOK"
    chmod +x "$HOOK"
    log "Updated: $HOOK"
  else
    log "Kept: $HOOK"
  fi
}
# === DOWNLOAD & INSTALL BINARY ===
get_binary() {
  get_arch
  log "Fetching latest AdGuard Home release..."

  # Fetch GitHub API
  if [ "$DOWNLOADER" = "curl" ]; then
    api=$(curl -kfsSL -A "Mozilla/5.0" "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)
  else
    api=$(wget -qO- --no-check-certificate "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)
  fi

  # Extract download URL for our architecture
  url=$(echo "$api" | grep "browser_download_url" | grep "$ARCH_MAP" | grep "tar.gz" | cut -d'"' -f4 | head -1)
  if [ -z "$url" ]; then
    die "No download URL found for architecture: $ARCH_MAP"
  fi

  # Prepare temp directory
  tmp="/tmp/ag-setup-$$"
  mkdir -p "$tmp"
  dl="$tmp/agh.tar.gz"

  # Download
  log "Downloading binary..."
  if [ "$DOWNLOADER" = "curl" ]; then
    curl -kfsSL -o "$dl" -A "Mozilla/5.0" "$url" 2>/dev/null
  else
    wget -qO "$dl" --no-check-certificate "$url" 2>/dev/null
  fi

  # Validate download
  if [ ! -s "$dl" ]; then
    die "Download failed: file is empty."
  fi
  sz=$(wc -c < "$dl")
  if [ "$sz" -lt 1000 ]; then
    die "Download failed: file too small ($sz bytes). Likely GitHub API error."
  fi

# Validate gzip archive (BusyBox safe) with debug info
  if ! tar -tzf "$dl" >/dev/null 2>&1; then
    # Show what we actually downloaded
    log "DEBUG: Download failed validation. URL: $url"
    log "DEBUG: File size: $sz bytes"
    log "DEBUG: First 200 chars: $(head -c 200 "$dl" | tr -d '\n\r')"
    # Check if it's HTML error page
    if head -c 100 "$dl" | grep -qi "<!DOCTYPE\|<html\|<body"; then
      die "Download failed: received HTML error page. GitHub API may be rate-limited."
    fi
    die "Not a valid gzip archive. Check URL or network."
  fi

  # Extract
  log "Extracting archive..."
  if ! tar -xzf "$dl" -C "$tmp"; then
    die "Extraction failed."
  fi

  # Find binary inside archive
  bin=$(find "$tmp" -name AdGuardHome -type f | head -1)
  if [ -z "$bin" ]; then
    die "Binary 'AdGuardHome' not found in archive."
  fi

  # Install
  log "Installing binary to $AGH_BIN..."
  cp -f "$bin" "$AGH_BIN"
  chmod +x "$AGH_BIN"
  rm -rf "$tmp"
  log "Binary installed successfully."
}
# === CREATE KEENETIC NETWORK POLICY ===
make_policy() {
  if ndmc -c "show ip policy" 2>/dev/null | grep -q "description = $POLICY_NAME"; then
    log "Policy already exists: $POLICY_NAME"
  else
    log "Creating policy: $POLICY_NAME..."
    ndmc -c "ip policy $POLICY_NAME" 2>/dev/null
    ndmc -c "ip policy $POLICY_NAME description $POLICY_NAME" 2>/dev/null
    ndmc -c "system configuration save" 2>/dev/null
    if [ $? -eq 0 ]; then
      log "Policy created and saved to startup config."
    else
      warn "CLI creation failed."
      warn "Please create manually: Web UI -> Network Rules -> Policies -> $POLICY_NAME"
    fi
  fi
}

# === INSTALL COMMAND ===
do_install() {
  log ">>> INSTALLATION STARTED"
  check_tools
  check_opkg
  deploy
  get_binary
  make_policy
  log "Starting AdGuard Home service..."
  $INIT start
  log ""
  log "INSTALLATION COMPLETE"
  log "1. Open http://<ROUTER_IP>:3000 in your browser"
  log "2. Complete the AdGuard Home setup wizard"
  log "3. Assign devices: Web UI -> Network Rules -> Policies -> $POLICY_NAME"
  log "Log file: $LOG"
}
# === UPDATE COMMAND ===
do_update() {
  log ">>> UPDATE STARTED"
  check_tools

  if [ ! -x "$AGH_BIN" ]; then
    die "AdGuard Home not found. Please run 'install' first."
  fi

  # Get current version
  cur=$("$AGH_BIN" --version 2>/dev/null | awk '{print $NF}')
  log "Current version: $cur"

  # Fetch latest from GitHub API
  log "Checking for updates..."
  if [ "$DOWNLOADER" = "curl" ]; then
    api=$(curl -kfsSL -A "Mozilla/5.0" "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)
  else
    api=$(wget -qO- --no-check-certificate "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)
  fi

  # Robust version parsing for BusyBox
  latest=$(echo "$api" | grep -o '"tag_name":[ ]*"[^"]*"' | head -1 | cut -d'"' -f4)

  if [ -z "$latest" ]; then
    warn "Could not determine latest version from GitHub."
    latest="unknown"
  else
    log "Latest version: $latest"
  fi

  # Compare versions
  if [ "$cur" = "$latest" ]; then
    log "Already up-to-date."
    exit 0
  fi

  # Ask before updating
  if ask "Update from $cur to $latest?"; then
    log "Backing up current binary to ${AGH_BIN}.bak..."
    cp -f "$AGH_BIN" "${AGH_BIN}.bak"
    get_binary
    log "Restarting service..."
    $INIT restart
    log "Successfully updated to $latest"
  else
    log "Update cancelled."
  fi
}

# === UNINSTALL COMMAND ===
do_uninstall() {
  log ">>> UNINSTALL STARTED"
  if ask "Stop service and remove all AdGuard Home files?"; then
    log "Stopping service..."
    $INIT stop 2>/dev/null
    log "Removing files..."
    rm -f "$AGH_BIN" "${AGH_BIN}.bak" "$CONF" "$INIT" "$HOOK"
    log "Files removed."
    log "NOTE: Network policy '$POLICY_NAME' was left intact."
    log "Remove it manually via Web UI if needed: Network Rules -> Policies"
  else
    log "Uninstall cancelled."
  fi
}

# === MAIN ENTRY POINT ===
case "${1:-}" in
  install)
    do_install
    ;;
  update)
    do_update
    ;;
  uninstall)
    do_uninstall
    ;;
  status)
    do_status
    ;;
  *)
    echo "Usage: $0 {install|update|uninstall|status}"
    echo ""
    echo "Commands:"
    echo "  install   - Deploy configs, download binary, create policy, start service"
    echo "  update    - Check GitHub, backup, replace binary, restart"
    echo "  uninstall - Stop service, remove files (keeps policy)"
    echo "  status    - Show current installation state"
    echo ""
    echo "Log file: $LOG"
    exit 1
    ;;
esac
