#!/bin/sh
# 99-adguard-dns.sh - KeeneticOS netfilter hook for AdGuard Home DNS routing
# Repository: https://github.com/arl-spb/AdGuardHome-Keenetic
# Note: Called synchronously by ndm. Must return immediately to avoid blocking network init.

[ -n "$table" ] && [ "$table" != "nat" ] && exit 0
export PATH=/opt/sbin:/opt/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Get policy mark once. If empty, ndm will call again in 1-2s.
MARK=$(ndmc -c "show ip policy" 2>/dev/null | awk '/description = adguard-clients/ {found=1} found && /mark:/ {print $2; exit}' | tr -d '\r\n ')
[ -z "$MARK" ] && exit 0

MARK_HEX="0x$MARK"
IPT="/opt/sbin/iptables"
TARGET="127.0.0.1:5354"

# Idempotent: remove old rules, add new at top of chain
$IPT -t nat -D PREROUTING -p udp --dport 53 -m mark --mark $MARK_HEX -j DNAT --to-destination $TARGET 2>/dev/null
$IPT -t nat -D PREROUTING -p tcp --dport 53 -m mark --mark $MARK_HEX -j DNAT --to-destination $TARGET 2>/dev/null
$IPT -t nat -I PREROUTING 1 -p udp --dport 53 -m mark --mark $MARK_HEX -j DNAT --to-destination $TARGET
$IPT -t nat -I PREROUTING 1 -p tcp --dport 53 -m mark --mark $MARK_HEX -j DNAT --to-destination $TARGET

exit 0
