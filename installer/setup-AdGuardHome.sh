#!/bin/sh
# setup-AdGuardHome.sh - Universal installer/updater for AdGuard Home on KeeneticOS
# Repository: https://github.com/arl-spb/AdGuardHome-Keenetic
# Usage: ./setup-AdGuardHome.sh {install|update|uninstall}

set -u

LOG="/tmp/ag-setup.log"
: > "$LOG"

log()  { echo "$1" | tee -a "$LOG"; }
die()  { log "❌ FATAL: $1"; exit 1; }
warn() { log "⚠️  WARNING: $1"; }
info() { log "ℹ️  INFO: $1"; }

# === CONFIGURATION ===
AGH_DIR="/opt/etc/AdGuardHome"
AGH_BIN="$AGH_DIR/AdGuardHome"
CONF="$AGH_DIR/ag-keenetic.conf"
INIT_SCRIPT="/opt/etc/init.d/S99adguardhome"
HOOK_SCRIPT="/opt/etc/ndm/netfilter.d/99-adguard-dns.sh"
POLICY_NAME="adguard-clients"
AGH_REPO="AdguardTeam/AdGuardHome"

# === ARCHITECTURE DETECTION ===
detect_arch() {
    local arch=$(uname -m)
    case "$arch" in
        aarch64|arm64)   ARCH_MAP="linux_arm64" ;;
        armv7l|armv7hf)  ARCH_MAP="linux_armv7" ;;
        x86_64)          ARCH_MAP="linux_amd64" ;;
        *)               die "Unsupported architecture: $arch (only arm64, armv7, x86_64)" ;;
    esac
    info "Detected architecture: $arch -> $ARCH_MAP"
}

# === OPKG CONFLICT CHECK ===
check_opkg_conflict() {
    if opkg list-installed 2>/dev/null | grep -q "adguardhome-go"; then
        log "⚠️  CONFLICT: Entware package 'adguardhome-go' is installed."
        log "   Running 'opkg upgrade' WILL overwrite your AdGuard Home binary."
        echo ""
        read -p "Choose action: [H]old & install safely | [R]emove opkg pkg | [C]ancel: " choice
        case "$choice" in
            [hH])
                opkg hold adguardhome-go 2>/dev/null
                info "Package 'adguardhome-go' marked as HELD. Proceeding..."
                ;;
            [rR])
                opkg remove adguardhome-go 2>/dev/null                info "Opkg package removed. Proceeding..."
                ;;
            [cC]|*)
                log "🛑 Installation CANCELLED by user. System unchanged."
                exit 0
                ;;
        esac
    fi
}

# === VERSION CHECK ===
check_version() {
    local local_ver=""
    [ -x "$AGH_BIN" ] && local_ver=$("$AGH_BIN" --version 2>/dev/null | awk '{print $NF}')
    [ -z "$local_ver" ] && local_ver="0.0.0"

    log "🔍 Checking latest version on GitHub..."
    local latest_ver
    latest_ver=$(wget -qO- --no-check-certificate "https://api.github.com/repos/$AGH_REPO/releases/latest" 2>/dev/null | grep -m1 '"tag_name"' | cut -d'"' -f4)
    
    if [ -z "$latest_ver" ]; then
        warn "Failed to fetch latest version. Proceeding with install/update..."
        return 0
    fi

    if [ "$local_ver" = "$latest_ver" ]; then
        log "✅ Already up-to-date ($local_ver). Nothing to do."
        exit 0
    fi
    log "📦 Current: $local_ver -> Latest: $latest_ver"
}

# === DOWNLOAD & EXTRACT ===
download_binary() {
    local tmp_dir="/tmp/ag-setup-$$"
    mkdir -p "$tmp_dir"
    cd "$tmp_dir" || die "Cannot cd to $tmp_dir"

    log "⬇️  Downloading AdGuard Home $latest_ver..."
    local url
    url=$(wget -qO- --no-check-certificate "https://api.github.com/repos/$AGH_REPO/releases/latest" 2>/dev/null | grep "browser_download_url.*${ARCH_MAP}.*tar.gz" | cut -d'"' -f4)
    [ -z "$url" ] && die "Failed to find download URL for $ARCH_MAP"

    wget -qO- --no-check-certificate "$url" | tar -xzf - || die "Download/Extraction failed"
    
    # Verify binary exists inside archive
    local inner_dir
    inner_dir=$(find . -type d -name "AdGuardHome" | head -1)
    [ -z "$inner_dir" ] && die "Archive structure unexpected"
        cp -f "$inner_dir/AdGuardHome" "$AGH_BIN" || die "Failed to copy binary"
    chmod +x "$AGH_BIN"
    rm -rf "$tmp_dir"
    log "✅ Binary installed to $AGH_BIN"
}

# === CREATE INTEGRATION CONFIG ===
create_config() {
    mkdir -p "$AGH_DIR"
    cat > "$CONF" << 'EOF'
# AdGuard Home ↔ Keenetic Integration Config
# Sourced by init script and ndm netfilter hook
AG_LISTEN_IP="127.0.0.1"
AG_LISTEN_PORT="5354"
AG_POLICY_NAME="adguard-clients"
EOF
    chmod 644 "$CONF"
    log "✅ Integration config created: $CONF"
}

# === DEPLOY SCRIPTS ===
deploy_scripts() {
    mkdir -p "$(dirname "$INIT_SCRIPT")" "$(dirname "$HOOK_SCRIPT")"

    # S99adguardhome
    cat > "$INIT_SCRIPT" << 'EOF'
#!/bin/sh
. /opt/etc/AdGuardHome/ag-keenetic.conf 2>/dev/null || { AG_LISTEN_PORT="5354"; }
ENABLED=yes; PROCS=AdGuardHome; DESC="AdGuard Home"
[ -x "/opt/bin/AdGuardHome" ] && BIN="/opt/bin/AdGuardHome"
[ -x "/opt/etc/AdGuardHome/AdGuardHome" ] && BIN="/opt/etc/AdGuardHome/AdGuardHome"
[ -z "$BIN" ] && exit 1
CONF="/opt/etc/AdGuardHome/AdGuardHome.yaml"
WORKDIR="/opt/etc/AdGuardHome"
LOG="/opt/tmp/AdGuardHome.log"
export PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
is_running() { pgrep -f "AdGuardHome" >/dev/null 2>&1; }
case "$1" in
  start)    is_running && exit 0; $BIN -c "$CONF" -w "$WORKDIR" --no-check-update >> "$LOG" 2>&1 & ;;
  stop)     killall AdGuardHome 2>/dev/null ;;
  restart)  killall AdGuardHome 2>/dev/null; sleep 1; $0 start ;;
  status)   is_running && echo "Running (port $AG_LISTEN_PORT)" || echo "Stopped" ;;
  *)        echo "Usage: $0 {start|stop|restart|status}"; exit 1 ;;
esac
exit 0
EOF
    chmod +x "$INIT_SCRIPT"

    # 99-adguard-dns.sh
    cat > "$HOOK_SCRIPT" << 'EOF'#!/bin/sh
[ -n "$table" ] && [ "$table" != "nat" ] && exit 0
. /opt/etc/AdGuardHome/ag-keenetic.conf 2>/dev/null || {
    AG_LISTEN_IP="127.0.0.1"; AG_LISTEN_PORT="5354"; AG_POLICY_NAME="adguard-clients"
}
export PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin
MARK=$(ndmc -c "show ip policy" 2>/dev/null | awk -v pol="$AG_POLICY_NAME" '$0 ~ "description = " pol {found=1} found && /mark:/ {print $2; exit}' | tr -d '\r\n ')
[ -z "$MARK" ] && exit 0
MARK_HEX="0x$MARK"
TARGET="${AG_LISTEN_IP}:${AG_LISTEN_PORT}"
IPT="/opt/sbin/iptables"
$IPT -t nat -D PREROUTING -p udp --dport 53 -m mark --mark $MARK_HEX -j DNAT --to-destination $TARGET 2>/dev/null
$IPT -t nat -D PREROUTING -p tcp --dport 53 -m mark --mark $MARK_HEX -j DNAT --to-destination $TARGET 2>/dev/null
$IPT -t nat -I PREROUTING 1 -p udp --dport 53 -m mark --mark $MARK_HEX -j DNAT --to-destination $TARGET
$IPT -t nat -I PREROUTING 1 -p tcp --dport 53 -m mark --mark $MARK_HEX -j DNAT --to-destination $TARGET
exit 0
EOF
    chmod +x "$HOOK_SCRIPT"
    log "✅ Init script and ndm hook deployed"
}

# === CREATE KEENETIC POLICY ===
create_policy() {
    if ndmc -c "show ip policy" 2>/dev/null | grep -q "description = $POLICY_NAME"; then
        log "✅ Policy '$POLICY_NAME' already exists. Skipping creation."
        return 0
    fi
    log "🛠  Creating Keenetic policy '$POLICY_NAME'..."
    if ndmc -c "ip policy $POLICY_NAME" 2>/dev/null && \
       ndmc -c "ip policy $POLICY_NAME description $POLICY_NAME" 2>/dev/null; then
        ndmc -c "system configuration save" 2>/dev/null
        log "✅ Policy created and saved to startup config."
    else
        warn "CLI creation failed. Create manually: Web UI → Network Rules → Policies → $POLICY_NAME"
    fi
}

# === INSTALL ===
do_install() {
    log "🚀 Starting AdGuard Home installation..."
    check_opkg_conflict
    detect_arch
    create_config
    deploy_scripts
    create_policy
    download_binary
    /opt/etc/init.d/S99adguardhome start
    log ""
    log "🎉 INSTALLATION COMPLETE!"
    log "👉 Next steps:"    log "   1. Open http://<ROUTER_IP>:3000 in your browser"
    log "   2. Complete AdGuard Home setup wizard (use 127.0.0.1:5354 for DNS)"
    log "   3. Assign devices: Web UI → Network Rules → Policies → $POLICY_NAME"
    log "📄 Full log: $LOG"
}

# === UPDATE ===
do_update() {
    log "🔄 Starting update check..."
    detect_arch
    check_version
    log "⬇️  Downloading newer version..."
    download_binary
    /opt/etc/init.d/S99adguardhome restart
    log "🎉 UPDATE COMPLETE! Service restarted."
    log "📄 Full log: $LOG"
}

# === UNINSTALL ===
do_uninstall() {
    log "🗑️  Starting uninstall..."
    /opt/etc/init.d/S99adguardhome stop 2>/dev/null
    rm -f "$AGH_BIN" "$CONF" "$INIT_SCRIPT" "$HOOK_SCRIPT"
    log "✅ Files removed. Policy '$POLICY_NAME' left intact (remove manually if needed)."
    log "📄 Full log: $LOG"
}

# === MAIN ===
case "${1:-}" in
    install)   do_install ;;
    update)    do_update ;;
    uninstall) do_uninstall ;;
    *)
        echo "Usage: $0 {install|update|uninstall}"
        echo "Log location: $LOG"
        exit 1
        ;;
esac
