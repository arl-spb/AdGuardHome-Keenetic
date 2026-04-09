#!/bin/sh
LOG="/tmp/ag-setup.log"; : > "$LOG"
log() { echo "$1" | tee -a "$LOG"; }
warn() { log "WARN: $1"; }
die() { log "FATAL: $1"; exit 1; }

REPO="arl-spb/AdGuardHome-Keenetic"; BRANCH="main"
RAW_BASE="https://raw.githubusercontent.com/$REPO/$BRANCH/installer"
AGH_DIR="/opt/etc/AdGuardHome"; AGH_BIN="$AGH_DIR/AdGuardHome"
CONF="$AGH_DIR/ag-keenetic.conf"
INIT="/opt/etc/init.d/S99adguardhome"
HOOK="/opt/etc/ndm/netfilter.d/99-adguard-dns.sh"
POLICY_NAME="adguard-clients"

get_arch() {
  case "$(uname -m)" in
    aarch64|arm64) ARCH_MAP="linux_arm64" ;;
    mipsel) ARCH_MAP="linux_mipsle_softfloat" ;;
    armv7l) ARCH_MAP="linux_armv7"; log "NOTE: ARMv7 experimental" ;;
    *) die "Unsupported: $(uname -m)" ;;
  esac; log "Arch: $(uname -m) -> $ARCH_MAP"
}

check_tools() {
  if command -v curl >/dev/null 2>&1; then DOWNLOADER="curl"; log "Using: curl"
  elif command -v wget >/dev/null 2>&1; then DOWNLOADER="wget"; log "Using: wget"
  else die "Install curl: opkg install curl"; fi
}

get_file() {
  if [ "$DOWNLOADER" = "curl" ]; then
    curl -kfsSL -o "$2" -A "Mozilla/5.0" "$1" 2>/dev/null
  else
    wget -qO "$2" --no-check-certificate "$1" 2>/dev/null
  fi; [ -s "$2" ]
}

ask() { printf "%s [y/N]: " "$1"; read r; [ "$r" = "y" ] || [ "$r" = "Y" ]; }

do_status() {
  log "=== STATUS ==="
  [ -x "$AGH_BIN" ] && log "Binary: OK ($("$AGH_BIN" --version 2>/dev/null | awk '{print $NF}'))" || log "Binary: MISSING"
  pgrep -f AdGuardHome >/dev/null 2>&1 && log "Service: RUNNING" || log "Service: STOPPED"
  [ -f "$CONF" ] && log "Config: OK" || log "Config: MISSING"
  [ -x "$INIT" ] && log "Init: OK" || log "Init: MISSING"
  [ -x "$HOOK" ] && log "Hook: OK" || log "Hook: MISSING"
  ndmc -c "show ip policy" 2>/dev/null | grep -q "description = $POLICY_NAME" && log "Policy: EXISTS" || log "Policy: MISSING"
  log "============"
}
check_opkg() {
  if opkg list-installed 2>/dev/null | grep -q "adguardhome-go"; then
    warn "Package adguardhome-go detected"; printf "Action: [H]old|[R]emove|[C]ancel: "; read a
    case "$a" in h|H) opkg hold adguardhome-go 2>/dev/null; log "HELD" ;;
      r|R) opkg remove adguardhome-go 2>/dev/null; log "REMOVED" ;; *) log "Cancelled"; exit 0 ;; esac
  fi
}

deploy() {
  mkdir -p "$AGH_DIR" "$(dirname "$INIT")" "$(dirname "$HOOK")"
  if [ ! -f "$CONF" ]; then
    get_file "$RAW_BASE/ag-keenetic.conf" "$CONF" 2>/dev/null || printf 'AG_LISTEN_IP="127.0.0.1"\nAG_LISTEN_PORT="5354"\nAG_POLICY_NAME="adguard-clients"\n' > "$CONF"
    chmod 644 "$CONF"; log "Created: $CONF"
  elif ask "Replace $CONF?"; then get_file "$RAW_BASE/ag-keenetic.conf" "$CONF" && chmod 644 "$CONF" && log "Updated: $CONF"; else log "Kept: $CONF"; fi
  if ask "Replace $INIT?"; then get_file "$RAW_BASE/S99adguardhome" "$INIT" && chmod +x "$INIT" && log "Updated: $INIT"; else log "Kept: $INIT"; fi
  if ask "Replace $HOOK?"; then get_file "$RAW_BASE/99-adguard-dns.sh" "$HOOK" && chmod +x "$HOOK" && log "Updated: $HOOK"; else log "Kept: $HOOK"; fi
}

get_binary() {
  get_arch; log "Fetching latest..."
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
  [ "$(wc -c < "$dl")" -lt 1000 ] && die "File too small"
  # FIX: BusyBox-safe gzip check via tar
  tar -tzf "$dl" >/dev/null 2>&1 || die "Not a valid gzip archive"
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
    log "Creating policy..."; ndmc -c "ip policy $POLICY_NAME" 2>/dev/null
    ndmc -c "ip policy $POLICY_NAME description $POLICY_NAME" 2>/dev/null    ndmc -c "system configuration save" 2>/dev/null
    [ $? -eq 0 ] && log "Policy saved" || warn "Create manually in Web UI"
  fi
}

do_install() { log ">>> INSTALL"; check_tools; check_opkg; deploy; get_binary; make_policy
  log "Starting..."; $INIT start; log "DONE. Open http://<IP>:3000"
}

do_update() {
  log ">>> UPDATE"; check_tools
  [ ! -x "$AGH_BIN" ] && die "Run install first"
  cur=$("$AGH_BIN" --version 2>/dev/null | awk '{print $NF}'); log "Current: $cur"
  if [ "$DOWNLOADER" = "curl" ]; then
    api=$(curl -kfsSL -A "Mozilla/5.0" "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)
  else
    api=$(wget -qO- --no-check-certificate "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)
  fi
  # FIX: Precise version parsing with sed
  latest=$(echo "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)
  log "Latest: ${latest:-unknown}"; [ "$cur" = "$latest" ] && log "Up-to-date" && exit 0
  if ask "Update to $latest?"; then
    log "Backing up..."; cp -f "$AGH_BIN" "${AGH_BIN}.bak"; get_binary
    log "Restarting..."; $INIT restart; log "Updated to $latest"
  else log "Cancelled"; fi
}

do_uninstall() {
  log ">>> UNINSTALL"
  if ask "Remove files?"; then $INIT stop 2>/dev/null
    rm -f "$AGH_BIN" "${AGH_BIN}.bak" "$CONF" "$INIT" "$HOOK"; log "Removed. Policy kept."
  else log "Cancelled"; fi
}

case "${1:-}" in install) do_install ;; update) do_update ;; uninstall) do_uninstall ;; status) do_status ;; *) echo "Usage: $0 {install|update|uninstall|status}"; exit 1 ;; esac
*)
      die "Unsupported for Keenetic: $arch
This script supports only:
  • aarch64 (ARM64) — Giga, Peak, Hero, Ultra, Skipper
  • mipsel (MIPS LE) — Omni, Lite, Start, Air, City
  • armv7l (ARMv7) — experimental"
      ;;
  esac
  log "Architecture: $arch -> $ARCH_MAP"
}

# === TOOL CHECK ===
check_tools() {
  if command -v curl >/dev/null 2>&1; then    DOWNLOADER="curl"
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

# === DOWNLOAD FILE ===
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

# === ASK CONFIRMATION ===
ask() {
  printf "%s [y/N]: " "$1"
  read r
  if [ "$r" = "y" ] || [ "$r" = "Y" ]; then
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
    log "Service: RUNNING"  else
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
    warn "Entware package 'adguardhome-go' detected"
    warn "'opkg upgrade' will overwrite your AdGuard Home binary"
    printf "Action: [H]old pkg | [R]emove pkg | [C]ancel: "
    read a
    case "$a" in
      h|H)
        opkg hold adguardhome-go 2>/dev/null
        log "Package HELD"
        ;;
      r|R)
        opkg remove adguardhome-go 2>/dev/null
        log "Package REMOVED"
        ;;
      *)
        log "Cancelled"
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

# === DOWNLOAD BINARY ===
get_binary() {
  get_arch
  log "Fetching latest AdGuard Home release..."

  if [ "$DOWNLOADER" = "curl" ]; then
    api=$(curl -kfsSL -A "Mozilla/5.0" "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)
  else
    api=$(wget -qO- --no-check-certificate "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)  fi

  url=$(echo "$api" | grep "browser_download_url.*${ARCH_MAP}.*tar.gz" | cut -d'"' -f4 | head -1)
  if [ -z "$url" ]; then
    die "No download URL for $ARCH_MAP"
  fi

  tmp="/tmp/ag-$$"
  mkdir -p "$tmp"
  dl="$tmp/agh.tar.gz"

  if [ "$DOWNLOADER" = "curl" ]; then
    curl -kfsSL -o "$dl" -A "Mozilla/5.0" "$url" 2>/dev/null
  else
    wget -qO "$dl" --no-check-certificate "$url" 2>/dev/null
  fi

  if [ ! -s "$dl" ]; then
    die "Download failed"
  fi

  sz=$(wc -c < "$dl")
  if [ "$sz" -lt 1000 ]; then
    die "File too small ($sz bytes) - likely error page"
  fi

  # FIX: BusyBox-compatible gzip validation via tar
  tar -tzf "$dl" >/dev/null 2>&1
  if [ $? -ne 0 ]; then
    die "Not a valid gzip archive"
  fi

  tar -xzf "$dl" -C "$tmp"
  if [ $? -ne 0 ]; then
    die "Extraction failed"
  fi

  bin=$(find "$tmp" -name AdGuardHome -type f | head -1)
  if [ -z "$bin" ]; then
    die "Binary not found in archive"
  fi

  cp -f "$bin" "$AGH_BIN"
  chmod +x "$AGH_BIN"
  rm -rf "$tmp"
  log "Installed: $AGH_BIN"
}

# === CREATE POLICY ===
make_policy() {  if ndmc -c "show ip policy" 2>/dev/null | grep -q "description = $POLICY_NAME"; then
    log "Policy exists: $POLICY_NAME"
  else
    log "Creating policy: $POLICY_NAME"
    ndmc -c "ip policy $POLICY_NAME" 2>/dev/null
    ndmc -c "ip policy $POLICY_NAME description $POLICY_NAME" 2>/dev/null
    ndmc -c "system configuration save" 2>/dev/null
    if [ $? -eq 0 ]; then
      log "Policy created & saved"
    else
      warn "CLI failed - create manually: Web UI → Network Rules → Policies → $POLICY_NAME"
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
  log "Starting service..."
  $INIT start
  log ""
  log "INSTALLATION COMPLETE"
  log "1. Open http://<ROUTER_IP>:3000"
  log "2. Complete wizard (DNS: 127.0.0.1:5354)"
  log "3. Assign devices: Web UI → Policies → $POLICY_NAME"
  log "Log: $LOG"
}

# === UPDATE ===
do_update() {
  log ">>> UPDATE"
  check_tools
  if [ ! -x "$AGH_BIN" ]; then
    die "Not installed. Run 'install' first."
  fi

  cur=$("$AGH_BIN" --version 2>/dev/null | awk '{print $NF}')
  log "Current: $cur"

  # Fetch API response
  if [ "$DOWNLOADER" = "curl" ]; then
    api=$(curl -kfsSL -A "Mozilla/5.0" "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)
  else
    api=$(wget -qO- --no-check-certificate "https://api.github.com/repos/AdguardTeam/AdGuardHome/releases/latest" 2>/dev/null)
  fi
  # FIX: Precise version parsing with sed
  latest=$(echo "$api" | sed -n 's/.*"tag_name": *"\([^"]*\)".*/\1/p' | head -1)

  log "Latest: ${latest:-unknown}"
  if [ "$cur" = "$latest" ]; then
    log "Already up-to-date"
    exit 0
  fi

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
case "${1:-}" in
  install)   do_install ;;
  update)    do_update ;;
  uninstall) do_uninstall ;;
  status)    do_status ;;
  *)
    echo "Usage: $0 {install|update|uninstall|status}"
    echo "  install   - Deploy components, download binary, create policy, start"
    echo "  update    - Check GitHub, backup, replace binary, restart"
    echo "  uninstall - Stop service, remove files (keep policy)"
    echo "  status    - Show current installation state"
    echo "Log: $LOG"
    exit 1
    ;;esac
