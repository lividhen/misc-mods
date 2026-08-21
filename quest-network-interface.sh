#!/usr/bin/env bash
#
# IMPORTANT
# This is a linux port of the repository here https://github.com/UbootVRC/Wired-Steam-Link-VR/
# Almost entirely ported by claude
#
# Quest USB NCM Link (Linux)
# --------------------------
# Puts the headset's USB port into NCM (USB Ethernet) mode and gives the
# resulting link a working IPv4 configuration, so Steam Link runs over the
# cable instead of Wi-Fi.
#
# This is a Linux port of a Windows PowerShell script. The USB/Android side
# is identical; only the host-side networking differs:
#
#   Windows                          Linux (this script)
#   --------------------------       --------------------------------
#   Get-NetAdapter / New-NetIPAddr   ip link / ip addr
#   hand-rolled DHCP server (Job)    dnsmasq --port=0 (DHCP only, no DNS)
#   New-NetNat + firewall rules      sysctl ip_forward + iptables MASQUERADE
#   Set-NetConnectionProfile         (not needed on Linux)
#   -                                nmcli device set <iface> managed no
#                                    (stops NetworkManager fighting us for
#                                    the interface/IP/route)
#
# Why it works the way it does (measured on a Quest 2 "hollywood",
# Android 14, build 52202280028100150, USB gadget HAL V2_0) - unchanged
# from the Windows version, reproduced here because it explains every
# step below:
#
#   * "svc usb setFunctions ncm,adb" is ALWAYS rejected. UsbService requires
#     exactly ONE function bit; adb is ORed in automatically whenever
#     adb_enabled is true. So the correct call is plain "ncm".
#
#   * RNDIS is not available on this hardware; NCM is the only USB network
#     gadget the device offers.
#
#   * Android's own Tethering service can't manage the link (empty
#     tetherableNcmRegexs on this build - the "could not enable IpServer for
#     function NCM" logcat line is a red herring, not what makes this work).
#
#   * What DOES work: Android's Ethernet service claims usb0 as a CLIENT
#     interface (interface filter matches usb\d) and runs a DHCP client on
#     it, broadcasting DHCPDISCOVER forever. All that's missing is a DHCP
#     server on the PC end - which is what dnsmasq provides here. On lease,
#     Android brings up a real ETHERNET network and routes over the cable.
#
#   * That Ethernet network only becomes the DEFAULT network once it
#     VALIDATES, which needs real internet - hence the NAT/forwarding setup
#     below. Without it, switch the headset's Wi-Fi off instead (--wifi-off).
#
#   * Any active VpnService on the headset captures uid 0-99999 and swallows
#     all app traffic regardless of routing - if the link looks perfect but
#     Steam Link still can't see the PC, check for that.
#
# Requirements: adb, ip (iproute2), dnsmasq, iptables. nmcli is optional but
# recommended (see above). Run as root, or the script will re-exec itself
# with sudo.

set -uo pipefail

# ----------------------------- configuration -----------------------------
SUBNET_BASE="192.168.42"
SUBNET_CIDR="${SUBNET_BASE}.0/24"
PC_IP="${SUBNET_BASE}.1"
PREFIX_LEN=24
DHCP_RANGE_LOW="${SUBNET_BASE}.2"
DHCP_RANGE_HIGH="${SUBNET_BASE}.10"
DNS_SERVERS="1.1.1.1,8.8.8.8"
LEASE_TIME="1h"
WORK_DIR="/run/quest-ncm-link"
LEASE_FILE="${WORK_DIR}/dnsmasq.leases"
DNSMASQ_PID_FILE="${WORK_DIR}/dnsmasq.pid"
DNSMASQ_LOG="${WORK_DIR}/dnsmasq.log"
FW_COMMENT="quest-ncm-link"
# -------------------------------------------------------------------------

# ------------------------------ flags -------------------------------------
WIFI_OFF=0
for arg in "$@"; do
    case "$arg" in
        --wifi-off|--no-internet) WIFI_OFF=1 ;;
        -h|--help)
            echo "Usage: $0 [--wifi-off]"
            echo "  --wifi-off   Switch the headset's Wi-Fi off instead of NATing"
            echo "               internet over the cable. Wi-Fi is restored on exit."
            echo "               This is also the automatic fallback if NAT setup fails."
            exit 0
            ;;
    esac
done

# --------------------------- re-exec as root -------------------------------
if [[ ${EUID} -ne 0 ]]; then
    exec sudo -E bash "$0" "$@"
fi

say()  { echo "  $*"; }
ok()   { echo -e "  \033[32m$*\033[0m"; }
warn() { echo -e "  \033[33m$*\033[0m"; }
fail() { echo -e "  \033[31m$*\033[0m"; }

echo ""
echo -e "  \033[36mQuest USB NCM Link\033[0m"
echo "  =================="
echo ""

mkdir -p "$WORK_DIR"

# ------------------------------ state ---------------------------------
ADB=""
SERIAL=""
IFACE=""
IP_MADE=0
NM_WAS_MANAGED=""
DNSMASQ_PID=""
FW_RULES=()        # array of "table -A/-D chain args..." we added, for reverse cleanup
IP_FORWARD_ORIG=""
NAT_MADE=0
WIFI_OFF_BY_US=0
RESTORED=0

restore_everything() {
    [[ $RESTORED -eq 1 ]] && return
    RESTORED=1
    echo ""
    say "Restoring..."

    if [[ -n "$DNSMASQ_PID" ]] && kill -0 "$DNSMASQ_PID" 2>/dev/null; then
        kill "$DNSMASQ_PID" 2>/dev/null
        wait "$DNSMASQ_PID" 2>/dev/null
    fi

    # Remove firewall/NAT rules in reverse order.
    for (( idx=${#FW_RULES[@]}-1 ; idx>=0 ; idx-- )); do
        # shellcheck disable=SC2086
        iptables ${FW_RULES[$idx]//-A/-D} 2>/dev/null
    done

    if [[ -n "$IP_FORWARD_ORIG" ]]; then
        sysctl -w net.ipv4.ip_forward="$IP_FORWARD_ORIG" >/dev/null 2>&1
    fi

    if [[ $IP_MADE -eq 1 && -n "$IFACE" ]]; then
        ip addr flush dev "$IFACE" 2>/dev/null
        ip link set dev "$IFACE" down 2>/dev/null
    fi

    if [[ -n "$NM_WAS_MANAGED" && -n "$IFACE" ]] && command -v nmcli >/dev/null 2>&1; then
        nmcli device set "$IFACE" managed "$NM_WAS_MANAGED" 2>/dev/null
    fi

    if [[ -n "$SERIAL" ]]; then
        if [[ $WIFI_OFF_BY_US -eq 1 ]]; then
            "$ADB" -s "$SERIAL" shell svc wifi enable >/dev/null 2>&1
            say "Headset Wi-Fi switched back on."
        fi
        # Blank function list = back to charging (+ adb).
        "$ADB" -s "$SERIAL" shell svc usb setFunctions >/dev/null 2>&1
    fi

    rm -rf "$WORK_DIR" 2>/dev/null
    ok "Done. USB is back to normal."
}
trap restore_everything EXIT INT TERM

add_fw_rule() {
    # $* is passed to iptables verbatim with -A; stored (with -A) so we can
    # flip it to -D on cleanup.
    iptables -A "$@" -m comment --comment "$FW_COMMENT"
    FW_RULES+=("-A $* -m comment --comment $FW_COMMENT")
}

# ------------------------------------------------------------- 1. find adb
say_step() { say "$*"; }

candidates=(
    "$(dirname "$(readlink -f "$0")")/adb"
    "$(dirname "$(readlink -f "$0")")/platform-tools/adb"
)
for c in "${candidates[@]}"; do
    if [[ -x "$c" ]]; then ADB="$c"; break; fi
done
if [[ -z "$ADB" ]]; then
    if command -v adb >/dev/null 2>&1; then
        ADB="$(command -v adb)"
    fi
fi
if [[ -z "$ADB" ]]; then
    fail "[X] adb was not found."
    say "    Install it (e.g. 'sudo apt install android-tools-adb') or put a"
    say "    standalone adb binary next to this script."
    exit 1
fi
"$ADB" start-server >/dev/null 2>&1

SERIAL="$("$ADB" devices | awk '$2=="device" && $1 !~ /:/ {print $1; exit}')"
if [[ -z "$SERIAL" ]]; then
    fail "[X] No headset found on USB."
    say "    - Is the cable plugged in?"
    say "    - Did you accept 'Allow USB debugging' in the headset?"
    exit 1
fi

if [[ ${#SERIAL} -gt 8 ]]; then
    serial_shown="${SERIAL:0:4}...${SERIAL: -4}"
else
    serial_shown="$SERIAL"
fi
say "[1/5] Headset on USB: $serial_shown"
say "      using adb: $ADB"

# ---------------------------------------------------- 2. switch USB to NCM
say "[2/5] Switching USB to NCM..."

# Snapshot interfaces before, so we can spot whichever new one shows up -
# more robust than assuming a name like usb0/enx..., which varies by distro
# and udev naming rules.
mapfile -t before_ifaces < <(ip -o link show | awk -F': ' '{print $2}')

"$ADB" -s "$SERIAL" shell svc usb setFunctions ncm >/dev/null 2>&1

IFACE=""
for _ in $(seq 1 20); do
    sleep 1
    mapfile -t now_ifaces < <(ip -o link show | awk -F': ' '{print $2}')
    for cand in "${now_ifaces[@]}"; do
        found=0
        for old in "${before_ifaces[@]}"; do
            [[ "$cand" == "$old" ]] && { found=1; break; }
        done
        if [[ $found -eq 0 ]]; then IFACE="$cand"; break; fi
    done
    [[ -n "$IFACE" ]] && break
done

if [[ -z "$IFACE" ]]; then
    fail "      No new network interface appeared."
    say  "      Confirm the gadget came up on the headset with:"
    say  "        adb shell svc usb getFunctions      (expect: ncm)"
    say  "      and check 'dmesg | tail' for USB errors on this end."
    exit 1
fi
ok "      Linux interface: '$IFACE'"

# Stop NetworkManager (if present) from fighting us for this interface -
# it will otherwise try to DHCP-client it, assign its own address, or flap
# the link while we're configuring it.
if command -v nmcli >/dev/null 2>&1; then
    NM_WAS_MANAGED="$(nmcli -g GENERAL.STATE device show "$IFACE" >/dev/null 2>&1 && echo yes || echo yes)"
    nmcli device set "$IFACE" managed no >/dev/null 2>&1
fi

# --------------------------------------------------- 3. address PC side
say "[3/5] Configuring the PC end (${PC_IP}/${PREFIX_LEN})..."
ip link set dev "$IFACE" up
ip addr flush dev "$IFACE" 2>/dev/null
ip addr add "${PC_IP}/${PREFIX_LEN}" dev "$IFACE"
IP_MADE=1

if command -v iptables >/dev/null 2>&1; then
    # Allow anything from the link's subnet in (Steam Link's own port rules
    # are usually scoped to a zone/profile that may not include this iface).
    add_fw_rule INPUT -i "$IFACE" -s "$SUBNET_CIDR" -j ACCEPT

    # DHCP requests arrive from 0.0.0.0 to 255.255.255.255, so they need
    # their own rule (a subnet-scoped rule above won't match a source of
    # 0.0.0.0).
    add_fw_rule INPUT -i "$IFACE" -p udp --dport 67 -j ACCEPT
else
    warn "      iptables not found - skipping firewall rules."
    warn "      If the lease never arrives, check your firewall manually."
fi

# Internet over the cable needs IP forwarding + NAT.
if [[ $WIFI_OFF -eq 0 ]]; then
    default_iface="$(ip route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -n1)"
    if [[ -z "$default_iface" ]]; then
        warn "      No default route found on this PC - can't NAT the cable."
        WIFI_OFF=1
    elif ! command -v iptables >/dev/null 2>&1; then
        warn "      iptables not found - can't NAT the cable."
        WIFI_OFF=1
    else
        IP_FORWARD_ORIG="$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)"
        sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1

        iptables -t nat -A POSTROUTING -s "$SUBNET_CIDR" -o "$default_iface" \
            -j MASQUERADE -m comment --comment "$FW_COMMENT"
        FW_RULES+=("-t nat -A POSTROUTING -s $SUBNET_CIDR -o $default_iface -j MASQUERADE -m comment --comment $FW_COMMENT")

        add_fw_rule FORWARD -i "$IFACE" -o "$default_iface" -j ACCEPT
        add_fw_rule FORWARD -i "$default_iface" -o "$IFACE" -m state --state ESTABLISHED,RELATED -j ACCEPT

        NAT_MADE=1
        ok "      NAT is up via '$default_iface' - the headset gets internet over the cable"
    fi
fi

# ------------------------------------------------- 4. serve DHCP on the link
say "[4/5] Serving DHCP on the link..."
if ! command -v dnsmasq >/dev/null 2>&1; then
    fail "      dnsmasq was not found."
    say  "      Install it, e.g.: sudo apt install dnsmasq"
    exit 1
fi

dnsmasq \
    --conf-file=/dev/null \
    --no-daemon \
    --interface="$IFACE" \
    --bind-interfaces \
    --except-interface=lo \
    --port=0 \
    --dhcp-range="${DHCP_RANGE_LOW},${DHCP_RANGE_HIGH},255.255.255.0,${LEASE_TIME}" \
    --dhcp-option=option:dns-server,"${DNS_SERVERS}" \
    --dhcp-option=option:router,"${PC_IP}" \
    --dhcp-leasefile="$LEASE_FILE" \
    --log-dhcp \
    --log-facility="$DNSMASQ_LOG" \
    >/dev/null 2>&1 &
DNSMASQ_PID=$!
sleep 1
if ! kill -0 "$DNSMASQ_PID" 2>/dev/null; then
    fail "      dnsmasq failed to start. Log:"
    tail -n 20 "$DNSMASQ_LOG" 2>/dev/null | sed 's/^/      /'
    say  "      A likely cause: something else already owns UDP 67"
    say  "      (another DHCP server, e.g. from a VM bridge or router-mode NM)."
    say  "      Check with: sudo ss -ulpn | grep :67"
    exit 1
fi

# ------------------------------------------------ 5. wait for the lease
say "[5/5] Waiting for the headset to take the lease..."
leased=0
for _ in $(seq 1 40); do
    sleep 2
    addr="$("$ADB" -s "$SERIAL" shell "ip -o -4 addr show usb0" 2>&1)"
    if [[ "$addr" == *"${SUBNET_BASE}."* ]]; then leased=1; break; fi
done

# Without NAT, the cable can't pass Android's internet check, so Wi-Fi stays
# the default network and the cable goes unused. Switching Wi-Fi off makes
# the cable the only route.
if [[ $leased -eq 1 && $NAT_MADE -eq 0 ]]; then
    say "      No internet on the cable, so switching the headset's"
    say "      Wi-Fi off to force traffic onto it."
    "$ADB" -s "$SERIAL" shell svc wifi disable >/dev/null 2>&1
    WIFI_OFF_BY_US=1
    sleep 5
fi

echo ""
echo "  ----------------------------------------------------------"
if [[ $leased -eq 1 ]]; then
    ok "  Link is up."
    echo ""
    echo "        Headset : $(grep -oE "${SUBNET_BASE}\.[0-9]+" "$LEASE_FILE" 2>/dev/null | head -n1)"
    echo "        This PC : $PC_IP"
    echo ""

    conn="$("$ADB" -s "$SERIAL" shell dumpsys connectivity 2>&1)"
    def="$(echo "$conn" | grep '^Active default network')"
    eth="$(echo "$conn" | grep 'Ethernet CONNECTED')"

    [[ -n "$eth" ]] && ok "  Headset has an ETHERNET network on the cable."
    say "  $def"

    if [[ $NAT_MADE -eq 1 ]]; then
        say "  Give it ~15s to validate, then it becomes the default"
        say "  network on its own. You can leave Wi-Fi on."
    else
        ok  "  Headset Wi-Fi is off, so the cable is its only route."
        say "  Steam Link does not need the headset to have internet."
        say "  Wi-Fi comes back when you press a key to exit."
    fi
    echo ""
    say "  In Steam Link, connect to $PC_IP"
else
    fail "  The headset never took a lease."
    echo ""
    say "  Check what the headset thinks its USB state is:"
    say "      adb shell svc usb getFunctions       (expect: ncm)"
    say "      adb logcat -d | grep DhcpClient      (expect: DHCPDISCOVER)"
    say "  And check this PC's dnsmasq log:"
    tail -n 15 "$DNSMASQ_LOG" 2>/dev/null | sed 's/^/      /'
fi
echo "  ----------------------------------------------------------"

echo ""
echo "  =========================================================="
echo "  Leave this window open while you play."
echo "  Press any key here to restore normal USB mode."
echo "  =========================================================="
read -n 1 -s -r
