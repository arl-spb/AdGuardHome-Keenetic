#!/bin/sh
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

check_tools() {
  if command -v curl >/dev/null 2>&1; then
    DOWNLOADER="curl"; log "Using: curl"
  elif command -v wget >/dev/null 2>&1; then
    DOWNLOADER="wget"; log "Using: wget"
  else
    die "Install curl: opkg install curl"
  fi
}

get_file() {
  if [ "$DOWNLOADER" = "curl" ]; then
    curl -kfsSL -o "$2" -A "Mozilla/5.0" "$1" 2>/dev/null
  else
    wget -qO "$2" --no-check-certificate "$1" 2>/dev/null
  fi
  [ -s "$2" ] && return 0 || return 1
}

ask() {
  printf "%s [y/N]: " "$1"
  read r
  [ "$r" = "y" ] || [ "$r" = "Y" ]
}
do_status() {
  log "=== STATUS ==="
  if [ -x "$AGH_BIN" ]; then
    v=$("$AGH_BIN" --version 2>/dev/null | awk '{print $NF}')
    log "Binary: OK ($v)"
  else
    log "Binary: MISSING"
  fi
  pgrep -f AdGuardHome >/dev/null 2>&1 && log "Service: RUNNING" || log "Service: STOPPED"
  [ -f "$CONF" ] && log "Config: OK" || log "Config: MISSING"
  [ -x "$INIT" ] && log "Init: OK" || log "Init: MISSING"
  [ -x "$HOOK" ] && log "Hook: OK" || log "Hook: MISSING"
  ndmc -c "show ip policy" 2>/dev/null | grep -q "description = $POLICY_NAME" && log "Policy: EXISTS" || log "Policy: MISSING"
  log "============"
}

check_opkg() {
  if opkg list-installed 2>/dev/null | grep -q "adguardhome-go"; then
    warn "Package adguardhome-go detected"
    printf "Action: [H]old | [R]emove | [C]ancel: "
    read a
    case "$a" in
      h|H) opkg hold adguardhome-go 2>/dev/null; log "HELD" ;;
      r|R) opkg remove adguardhome-go 2>/dev/null; log "REMOVED" ;;
      *) log "Cancelled"; exit 0 ;;
    esac
  fi
}

deploy() {
  mkdir -p "$AGH_DIR" "$(dirname "$INIT")" "$(dirname "$HOOK")"
  if [ ! -f "$CONF" ]; then
    get_file "$RAW_BASE/ag-keenetic.conf" "$CONF" 2>/dev/null
    if [ $? -ne 0 ]; then
      printf 'AG_LISTEN_IP="127.0.0.1"\nAG_LISTEN_PORT="5354"\nAG_POLICY_NAME="adguard-clients"\n' > "$CONF"
    fi
    chmod 644 "$CONF"; log "Created: $CONF"
  else
    if ask "Replace $CONF?"; then
      get_file "$RAW_BASE/ag-keenetic.conf" "$CONF"; chmod 644 "$CONF"; log "Updated: $CONF"
    else
      log "Kept: $CONF"
    fi
  fi
  if ask "Replace $INIT?"; then
    get_file "$RAW_BASE/S99adguardhome" "$INIT"; chmod +x "$INIT"; log "Updated: $INIT"
  else
    log "Kept: $INIT"
  fi
  if ask "Replace $HOOK?"; then
    get_file "$RAW_BASE/99-adguard-dns.sh" "$HOOK"; chmod +x "$HOOK"; log "Updated: $HOOK"
  else
    log "Kept: $HOOK"
  fi
}
get_binary() {
  get_arch
  log "Fetching latest..."
  if [ "$DOWNLOADER" = "curl" ]; then
    api=$(curl -kfsSL -A "Mozilla/5.0" "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)
  else
    api=$(wget -qO- --no-check-certificate "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)
  fi
  url=$(echo "$api" | grep "browser_download_url.*${ARCH_MAP}.*tar.gz" | cut -d'"' -f4 | head -1)
  [ -z "$url" ] && die "No URL for $ARCH_MAP"
  tmp="/tmp/ag-$$"; mkdir -p "$tmp"; dl="$tmp/agh.tar.gz"
  if [ "$DOWNLOADER" = "curl" ]; then
    curl -kfsSL -o "$dl" -A "Mozilla/5.0" "$url" 2>/dev/null
  else
    wget -qO "$dl" --no-check-certificate "$url" 2>/dev/null
  fi
  [ ! -s "$dl" ] && die "Download failed"
  sz=$(wc -c < "$dl"); [ "$sz" -lt 1000 ] && die "File too small"
  magic=$(od -t x1 -N 2 "$dl" 2>/dev/null | awk 'NR==1{print $2$3}')
  [ "$magic" != "1f8b" ] && die "Not gzip (magic: $magic)"
  tar -xzf "$dl" -C "$tmp" || die "Extract failed"
  bin=$(find "$tmp" -name AdGuardHome -type f | head -1)
  [ -z "$bin" ] && die "Binary not found"
  cp -f "$bin" "$AGH_BIN"; chmod +x "$AGH_BIN"; rm -rf "$tmp"
  log "Installed: $AGH_BIN"
}

make_policy() {
  if ndmc -c "show ip policy" 2>/dev/null | grep -q "description = $POLICY_NAME"; then
    log "Policy exists: $POLICY_NAME"
  else
    log "Creating policy..."
    ndmc -c "ip policy $POLICY_NAME" 2>/dev/null
    ndmc -c "ip policy $POLICY_NAME description $POLICY_NAME" 2>/dev/null
    ndmc -c "system configuration save" 2>/dev/null
    [ $? -eq 0 ] && log "Policy saved" || warn "Create manually in Web UI"
  fi
}

do_install() {
  log ">>> INSTALL"
  check_tools; check_opkg; deploy; get_binary; make_policy
  log "Starting..."
  $INIT start
  log "DONE. Open http://<IP>:3000"
}

do_update() {
  log ">>> UPDATE"
  check_tools
  [ ! -x "$AGH_BIN" ] && die "Run install first"
  cur=$("$AGH_BIN" --version 2>/dev/null | awk '{print $NF}')
  log "Current: $cur"
  if [ "$DOWNLOADER" = "curl" ]; then
    api=$(curl -kfsSL -A "Mozilla/5.0" "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)
  else
    api=$(wget -qO- --no-check-certificate "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)
  fi
  latest=$(echo "$api" | grep '"tag_name"' | head -1 | cut -d'"' -f4)
  log "Latest: ${latest:-unknown}"
  if [ "$cur" = "$latest" ]; then log "Up-to-date"; exit 0; fi
  if ask "Update to $latest?"; then
    log "Backing up..."
    cp -f "$AGH_BIN" "${AGH_BIN}.bak"
    get_binary
    log "Restarting..."
    $INIT restart
    log "Updated to $latest"
  else
    log "Cancelled"
  fi
}

do_uninstall() {
  log ">>> UNINSTALL"
  if ask "Remove files?"; then
    $INIT stop 2>/dev/null
    rm -f "$AGH_BIN" "${AGH_BIN}.bak" "$CONF" "$INIT" "$HOOK"
    log "Removed. Policy kept."
  else
    log "Cancelled"
  fi
}

case "${1:-}" in
  install) do_install ;;
  update) do_update ;;
  uninstall) do_uninstall ;;
  status) do_status ;;
  *) echo "Usage: $0 {install|update|uninstall|status}"; exit 1 ;;
esac
