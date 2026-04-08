#!/bin/sh
# setup-AdGuardHome.sh - Installer, Updater & Uninstaller for KeeneticOS 5.x+
# Repository: https://github.com/arl-spb/AdGuardHome-Keenetic
set -e

# --- Configuration ---
REPO="AdguardTeam/AdGuardHome"
BIN_PATH="/opt/bin/AdGuardHome"
CONF_DIR="/opt/etc/AdGuardHome"
CONF_FILE="${CONF_DIR}/AdGuardHome.yaml"
PID_DIR="/opt/var/run"
LOG="/opt/tmp/AdGuardHome.log"
INIT_DEST="/opt/etc/init.d/S99adguardhome"
INIT_URL="https://raw.githubusercontent.com/arl-spb/AdGuardHome-Keenetic/main/installer/S99adguardhome"
MANAGER_PATH="/opt/bin/setup-AdGuardHome.sh"
SCRIPT_VERSION="1.2.0"

# --- Helpers ---
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
info()  { echo -e "${BLUE}[ℹ]${NC} $1"; }
ok()    { echo -e "${GREEN}[✓]${NC} $1"; }
warn()  { echo -e "${YELLOW}[!]${NC} $1"; }
err()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }

# 🔹 Self-installation: if run from temp or piped, save to /opt/bin/ and re-exec
SELF_PATH="$(realpath "$0" 2>/dev/null || echo "$0")"
if [ "$SELF_PATH" != "$MANAGER_PATH" ]; then
    info "Installing manager to $MANAGER_PATH..."
    mkdir -p /opt/bin
    if [ -t 0 ]; then
        cp "$SELF_PATH" "$MANAGER_PATH" 2>/dev/null || err "Failed to copy manager. Run as root."
    else
        cat > "$MANAGER_PATH"
    fi
    chmod +x "$MANAGER_PATH"
    ok "Manager saved. Restarting from persistent location..."
    exec "$MANAGER_PATH" "$@"
    exit 0
fi

# --- Core Functions ---
do_install() {
    command -v curl >/dev/null 2>&1 || err "curl not found: opkg install curl"
    command -v tar  >/dev/null 2>&1 || err "tar not found: opkg install tar"

    ARCH=$(uname -m)
    case "$ARCH" in
        aarch64|arm64)   ADG_ARCH="linux_arm64" ;;
        armv7l|armv7|arm) ADG_ARCH="linux_arm" ;;
        mips|mipsel)     ADG_ARCH="linux_mipsle_softfloat" ;;        *)               err "Unsupported architecture: $ARCH" ;;
    esac
    info "Architecture: $ARCH → $ADG_ARCH"

    info "Fetching latest AdGuard Home..."
    API_URL="https://api.github.com/repos/${REPO}/releases/latest"
    LATEST_JSON=$(curl -s -f -H "Accept: application/vnd.github.v3+json" "$API_URL" 2>/dev/null || echo "")
    [ -z "$LATEST_JSON" ] && err "Failed to fetch GitHub API. Check internet."

    VERSION=$(echo "$LATEST_JSON" | grep '"tag_name"' | head -1 | sed 's/.*"v\(.*\)".*/\1/')
    FILENAME="AdGuardHome_${ADG_ARCH}_v${VERSION}.tar.gz"
    DOWNLOAD_URL="https://github.com/${REPO}/releases/download/v${VERSION}/${FILENAME}"
    CHECKSUM_URL="${DOWNLOAD_URL}.sha256"

    info "Target version: v${VERSION}"

    TMP_DIR="/tmp/ag_setup_$$"
    mkdir -p "$TMP_DIR" "$CONF_DIR" "$PID_DIR"
    trap "rm -rf $TMP_DIR" EXIT

    info "Downloading binary..."
    curl -L -s -o "${TMP_DIR}/${FILENAME}" "$DOWNLOAD_URL" || err "Download failed"

    if command -v sha256sum >/dev/null 2>&1; then
        info "Verifying SHA256..."
        EXPECTED=$(curl -s -L "$CHECKSUM_URL" 2>/dev/null | awk '{print $1}')
        ACTUAL=$(sha256sum "${TMP_DIR}/${FILENAME}" | awk '{print $1}')
        [ -n "$EXPECTED" ] && [ "$EXPECTED" != "$ACTUAL" ] && err "Checksum mismatch! Aborting."
        ok "Integrity verified"
    fi

    [ -f "$CONF_FILE" ] && cp "$CONF_FILE" "${CONF_FILE}.bak" && ok "Config backed up"

    info "Deploying binary to $BIN_PATH..."
    tar -xzf "${TMP_DIR}/${FILENAME}" -C "$TMP_DIR" >/dev/null 2>&1
    mv "${TMP_DIR}/AdGuardHome/AdGuardHome" "$BIN_PATH"
    chmod +x "$BIN_PATH"

    if [ ! -f "$INIT_DEST" ] || ! grep -q "arl-spb/AdGuardHome-Keenetic" "$INIT_DEST" 2>/dev/null; then
        info "Deploying init script..."
        curl -s -L "$INIT_URL" -o "$INIT_DEST"
        chmod +x "$INIT_DEST"
        ok "Init script: $INIT_DEST"
    else
        info "Init script up-to-date"
    fi

    info "Starting AdGuard Home..."
    $INIT_DEST restart >/dev/null 2>&1 || $INIT_DEST start >/dev/null 2>&1
    sleep 2
    if $INIT_DEST status >/dev/null 2>&1 || pgrep -f "AdGuardHome" >/dev/null 2>&1; then
        ok "AdGuard Home v${VERSION} is running!"
        IP=$(ip route get 1 2>/dev/null | awk '{print $7; exit}')
        echo -e "${GREEN}🌐 Web UI: http://${IP}:3000${NC}"
    else
        warn "Service may still be starting. Check: tail -f $LOG"
    fi
}

do_uninstall() {
    info "Uninstalling AdGuard Home..."
    [ -f "$INIT_DEST" ] && $INIT_DEST stop >/dev/null 2>&1
    killall AdGuardHome 2>/dev/null || true
    sleep 1

    rm -f "$BIN_PATH"
    rm -f "$INIT_DEST"
    rm -f "$LOG"
    rm -f "/opt/var/run/adguardhome.pid"
    rm -f "$MANAGER_PATH"

    warn "Config directory $CONF_DIR kept. Remove manually with: rm -rf $CONF_DIR"
    ok "Uninstall complete."
}

# --- Main ---
case "${1:-install}" in
    install|update|--update)
        do_install
        ;;
    uninstall|--uninstall)
        do_uninstall
        ;;
    *)
        echo "Usage: $MANAGER_PATH {install|update|uninstall}"
        exit 1
        ;;
esac
exit 0
