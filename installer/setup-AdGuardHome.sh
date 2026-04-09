#!/bin/sh
# setup-AdGuardHome.sh - Minimal reliable installer for Keenetic
LOG="/tmp/ag-setup.log"
: > "$LOG"
log() { echo "$1" | tee -a "$LOG"; }
warn() { log "WARN: $1"; }
die() { log "FATAL: $1"; exit 1; }

REPO="arl-spb/AdGuardHome-Keenetic"
BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH/installer"
AGH_DIR="/opt/etc/AdGuardHome"
AGH_BIN="$AGH_DIR/AdGuardHome"
CONF="$AGH_DIR/ag-keenetic.conf"
INIT="/opt/etc/init.d/S99adguardhome"
HOOK="/opt/etc/ndm/netfilter.d/99-adguard-dns.sh"
POLICY_NAME="adguard-clients"

# === ARCH ===
get_arch() {
  arch=$(uname -m)
  case "$arch" in
    aarch64|arm64) ARCH_MAP="linux_arm64" ;;
    mipsel) ARCH_MAP="linux_mipsle_softfloat" ;;
    armv7l) ARCH_MAP="linux_armv7"; log "NOTE: ARMv7 experimental" ;;
    *) die "Unsupported: $arch" ;;
  esac
  log "Arch: $arch -> $ARCH_MAP"
}

# === TOOLS ===
check_tools() {
  if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"
    log "Using: curl"
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"
    log "Using: wget"
  else
    die "Install curl: opkg install curl"
  fi
}

# === DOWNLOAD FILE ===
get_file() {
  url="$1"
  out="$2"
  if [ "$DOWNLOADER" = "curl" ]; then
    curl -kfsSL -o "$out" -A "Mozilla/5.0" "$url" 2>/dev/null
  else    wget -qO "$out" --no-check-certificate "$url" 2>/dev/null
  fi
  if [ -s "$out" ]; then
    return 0
  else
    return 1
  fi
}

# === ASK YES/NO ===
ask() {
  printf "%s [y/N]: " "$1"
  read answer
  if [ "$answer" = "y" ] || [ "$answer" = "Y" ]; then
    return 0
  else
    return 1
  fi
}

# === STATUS ===
do_status() {
  log "=== STATUS ==="
  if [ -x "$AGH_BIN" ]; then
    ver=$("$AGH_BIN" --version 2>/dev/null | awk '{print $NF}')
    log "Binary: OK ($ver)"
  else
    log "Binary: MISSING"
  fi
  if pgrep -f AdGuardHome >/dev/null 2>&1; then
    log "Service: RUNNING"
  else
    log "Service: STOPPED"
  fi
  if [ -f "$CONF" ]; then
    log "Config: OK"
  else
    log "Config: MISSING"
  fi
  if [ -x "$INIT" ]; then
    log "Init: OK"
  else
    log "Init: MISSING"
  fi
  if [ -x "$HOOK" ]; then
    log "Hook: OK"
  else
    log "Hook: MISSING"
  fi
  if ndmc -c "show ip policy" 2>/dev/null | grep -q "description = $POLICY_NAME"; then    log "Policy: EXISTS"
  else
    log "Policy: MISSING"
  fi
  log "============"
}

# === OPKG CHECK ===
check_opkg() {
  if opkg list-installed 2>/dev/null | grep -q "adguardhome-go"; then
    warn "Package adguardhome-go detected"
    printf "Action: [H]old | [R]emove | [C]ancel: "
    read action
    case "$action" in
      h|H) opkg hold adguardhome-go 2>/dev/null; log "HELD" ;;
      r|R) opkg remove adguardhome-go 2>/dev/null; log "REMOVED" ;;
      *) log "Cancelled"; exit 0 ;;
    esac
  fi
}

# === DEPLOY FILES ===
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
  
  # Init
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

# === DOWNLOAD BINARY ===
get_binary() {
  get_arch
  log "Fetching latest AdGuard Home..."
  
  # Get API
  if [ "$DOWNLOADER" = "curl" ]; then
    api=$(curl -kfsSL -A "Mozilla/5.0" "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)
  else
    api=$(wget -qO- --no-check-certificate "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)
  fi
  
  # Get URL for our arch
  url=$(echo "$api" | grep "browser_download_url" | grep "$ARCH_MAP" | grep "tar.gz" | cut -d'"' -f4 | head -1)
  if [ -z "$url" ]; then
    die "No download URL for $ARCH_MAP"
  fi
  
  tmp="/tmp/ag-$$"
  mkdir -p "$tmp"
  dl="$tmp/agh.tar.gz"
  
  # Download
  if [ "$DOWNLOADER" = "curl" ]; then
    curl -kfsSL -o "$dl" -A "Mozilla/5.0" "$url" 2>/dev/null
  else
    wget -qO "$dl" --no-check-certificate "$url" 2>/dev/null
  fi
  
  if [ ! -s "$dl" ]; then
    die "Download failed"
  fi
  
  # Check size
  sz=$(wc -c < "$dl")
  if [ "$sz" -lt 1000 ]; then
    die "File too small ($sz bytes)"
  fi  
  # Validate gzip via tar (BusyBox-safe)
  if ! tar -tzf "$dl" >/dev/null 2>&1; then
    die "Not a valid gzip archive"
  fi
  
  # Extract
  if ! tar -xzf "$dl" -C "$tmp"; then
    die "Extraction failed"
  fi
  
  # Find binary
  bin=$(find "$tmp" -name AdGuardHome -type f | head -1)
  if [ -z "$bin" ]; then
    die "Binary not found in archive"
  fi
  
  # Install
  cp -f "$bin" "$AGH_BIN"
  chmod +x "$AGH_BIN"
  rm -rf "$tmp"
  log "Installed: $AGH_BIN"
}

# === POLICY ===
make_policy() {
  if ndmc -c "show ip policy" 2>/dev/null | grep -q "description = $POLICY_NAME"; then
    log "Policy exists: $POLICY_NAME"
  else
    log "Creating policy: $POLICY_NAME"
    ndmc -c "ip policy $POLICY_NAME" 2>/dev/null
    ndmc -c "ip policy $POLICY_NAME description $POLICY_NAME" 2>/dev/null
    ndmc -c "system configuration save" 2>/dev/null
    if [ $? -eq 0 ]; then
      log "Policy saved"
    else
      warn "Create manually in Web UI"
    fi
  fi
}

# === INSTALL ===
do_install() {
  log ">>> INSTALL"
  check_tools
  check_opkg
  deploy
  get_binary
  make_policy
  log "Starting service..."  $INIT start
  log ""
  log "INSTALLATION COMPLETE"
  log "1. Open http://<ROUTER_IP>:3000"
  log "2. Complete wizard (DNS: 127.0.0.1:5354)"
  log "3. Assign devices: Web UI -> Policies -> $POLICY_NAME"
  log "Log: $LOG"
}

# === UPDATE ===
do_update() {
  log ">>> UPDATE"
  check_tools
  
  if [ ! -x "$AGH_BIN" ]; then
    die "Not installed. Run 'install' first."
  fi
  
  # Current version
  cur=$("$AGH_BIN" --version 2>/dev/null | awk '{print $NF}')
  log "Current version: $cur"
  
  # Fetch latest from GitHub API
  if [ "$DOWNLOADER" = "curl" ]; then
    api=$(curl -kfsSL -A "Mozilla/5.0" "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)
  else
    api=$(wget -qO- --no-check-certificate "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)
  fi
  
  # Parse tag_name - simple grep/cut, tested
  latest=$(echo "$api" | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": "//' | sed 's/".*//')
  
  if [ -z "$latest" ]; then
    warn "Could not fetch latest version"
    latest="unknown"
  fi
  
  log "Latest version: $latest"
  
  # Compare versions
  if [ "$cur" = "$latest" ]; then
    log "Already up-to-date"
    exit 0
  fi
  
  # Ask before update
  if ask "Update from $cur to $latest?"; then
    log "Backing up current binary..."
    cp -f "$AGH_BIN" "${AGH_BIN}.bak"
    get_binary    log "Restarting service..."
    $INIT restart
    log "Updated to $latest"
  else
    log "Update cancelled by user"
  fi
}

# === UNINSTALL ===
do_uninstall() {
  log ">>> UNINSTALL"
  if ask "Stop service and remove files?"; then
    $INIT stop 2>/dev/null
    rm -f "$AGH_BIN" "${AGH_BIN}.bak" "$CONF" "$INIT" "$HOOK"
    log "Files removed"
    log "Policy '$POLICY_NAME' kept. Remove via Web UI if needed."
  else
    log "Cancelled"
  fi
}

# === MAIN ===
cmd="${1:-}"
case "$cmd" in
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
    echo "Log: $LOG"
    exit 1
    ;;
esac
