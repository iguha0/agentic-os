#!/bin/sh
# CGI: POST /cgi-bin/wifi.sh  — Wi-Fi settings for PryzentOS phones
# Body: cmd=status | cmd=scan | cmd=connect&ssid=<s>&psk=<p> | cmd=forget&ssid=<s>
# Returns JSON. Networks are saved to the persistent wpa_supplicant config.

echo "Content-Type: application/json"
echo ""

read -r body
qs="${QUERY_STRING}&${body}"
urldecode() { printf '%b' "$(printf '%s' "$1" | sed 's/+/ /g; s/%\([0-9A-Fa-f][0-9A-Fa-f]\)/\\x\1/g')"; }
get() { urldecode "$(printf '%s' "$qs" | tr '&' '\n' | grep "^$1=" | head -1 | cut -d= -f2-)"; }
json_str() { printf '"%s"' "$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr -d '\000-\037')"; }
hex() { printf '%s' "$1" | od -An -tx1 | tr -d ' \n'; }

WLAN=$(cat /run/pryzent-wlan 2>/dev/null)
CTRL=/run/wpa_supplicant
wpa() { wpa_cli -p "$CTRL" -i "$WLAN" "$@" 2>/dev/null; }

ensure_up() {
    if [ -z "$WLAN" ] || ! wpa status >/dev/null; then
        /usr/local/bin/pryzent-phone wifi-up >/dev/null 2>&1
        WLAN=$(cat /run/pryzent-wlan 2>/dev/null)
    fi
    if [ -z "$WLAN" ]; then
        echo '{"ok":false,"error":"No Wi-Fi hardware available on this kernel. Use USB networking instead."}'
        exit 0
    fi
}

CMD=$(get cmd)
case "${CMD:-status}" in
    status)
        if [ -z "$WLAN" ]; then
            echo '{"ok":true,"iface":null,"state":"unavailable"}'
            exit 0
        fi
        ST=$(wpa status)
        SSID=$(printf '%s\n' "$ST" | grep '^ssid=' | cut -d= -f2-)
        STATE=$(printf '%s\n' "$ST" | grep '^wpa_state=' | cut -d= -f2)
        IP=$(ip -4 addr show "$WLAN" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
        printf '{"ok":true,"iface":%s,"state":%s,"ssid":%s,"ip":%s}\n' \
            "$(json_str "$WLAN")" "$(json_str "${STATE:-DOWN}")" "$(json_str "$SSID")" "$(json_str "$IP")"
        ;;
    scan)
        ensure_up
        wpa scan >/dev/null
        sleep 4
        printf '{"ok":true,"networks":['
        first=1
        # bssid / frequency / signal level / flags / ssid  (tab separated)
        wpa scan_results | tail -n +2 | sort -t "$(printf '\t')" -k3 -n -r |
        while IFS="$(printf '\t')" read -r bssid freq sig flags ssid; do
            [ -n "$ssid" ] || continue
            case "$flags" in *WPA*|*RSN*|*SAE*) sec=true ;; *) sec=false ;; esac
            [ $first -eq 1 ] || printf ','
            first=0
            printf '{"ssid":%s,"signal":%s,"secure":%s}' "$(json_str "$ssid")" "${sig:-0}" "$sec"
        done
        echo ']}'
        ;;
    connect)
        ensure_up
        SSID=$(get ssid); PSK=$(get psk)
        [ -n "$SSID" ] || { echo '{"ok":false,"error":"missing ssid"}'; exit 0; }
        N=$(wpa add_network | tail -n 1)
        wpa set_network "$N" ssid "$(hex "$SSID")" >/dev/null
        if [ -n "$PSK" ]; then
            # Store the derived key, never the plain passphrase.
            KEY=$(wpa_passphrase "$SSID" "$PSK" 2>/dev/null | grep -E '^[[:space:]]*psk=' | cut -d= -f2)
            [ -n "$KEY" ] || { wpa remove_network "$N" >/dev/null
                               echo '{"ok":false,"error":"password must be 8-63 characters"}'; exit 0; }
            wpa set_network "$N" psk "$KEY" >/dev/null
        else
            wpa set_network "$N" key_mgmt NONE >/dev/null
        fi
        wpa enable_network "$N" >/dev/null
        wpa select_network "$N" >/dev/null
        wpa save_config >/dev/null
        i=0
        while [ $i -lt 20 ]; do
            wpa status | grep -q '^wpa_state=COMPLETED' && break
            i=$((i + 1)); sleep 1
        done
        if [ $i -ge 20 ]; then
            echo '{"ok":false,"error":"could not join (wrong password or out of range)"}'
            exit 0
        fi
        # DHCP is handled by the background udhcpc; give it a moment.
        sleep 3
        IP=$(ip -4 addr show "$WLAN" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
        printf '{"ok":true,"ssid":%s,"ip":%s}\n' "$(json_str "$SSID")" "$(json_str "$IP")"
        ;;
    forget)
        ensure_up
        SSID=$(get ssid)
        wpa list_networks | tail -n +2 | while IFS="$(printf '\t')" read -r id ssid rest; do
            [ "$ssid" = "$SSID" ] && wpa remove_network "$id" >/dev/null
        done
        wpa save_config >/dev/null
        echo '{"ok":true}'
        ;;
    *)
        echo '{"ok":false,"error":"unknown cmd"}'
        ;;
esac
