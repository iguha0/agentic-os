#!/bin/sh
# CGI: GET /cgi-bin/fdroid.sh?q=<query>          search F-Droid catalogue
#      GET /cgi-bin/fdroid.sh?download=<pkg>     download latest APK to inbox
#
# PryzentOS has no Android runtime: APKs are take-away artifacts
# (transfer/sideload onto Android devices from the Files app or shares).

echo "Content-Type: application/json"
echo "Access-Control-Allow-Origin: *"
echo ""

qs="$QUERY_STRING"
Q=$(printf '%s' "$qs" | grep -o 'q=[^&]*' | head -1 | cut -d= -f2- | sed 's/+/ /g; s/%20/ /g')
PKG=$(printf '%s' "$qs" | grep -o 'download=[^&]*' | head -1 | cut -d= -f2-)
FDROID="https://f-droid.org"

if [ -n "$PKG" ]; then
    META=$(wget -q -T 15 -O - "$FDROID/api/v1/packages/$PKG" 2>/dev/null)
    VC=$(printf '%s' "$META" | grep -o '"suggestedVersionCode":[0-9]*' | cut -d: -f2)
    [ -z "$VC" ] && echo '{"ok":false,"error":"unknown package"}' && exit 0
    APK="${PKG}_${VC}.apk"
    mkdir -p /usr/share/agentic/inbox
    OUT="/usr/share/agentic/inbox/$APK"
    if wget -q -T 180 -O "$OUT" "$FDROID/repo/$APK" 2>/dev/null && [ -s "$OUT" ]; then
        SIZE=$(wc -c < "$OUT")
        echo "{\"ok\":true,\"file\":\"$OUT\",\"size\":$SIZE,\"apk\":\"$APK\"}"
    else
        rm -f "$OUT"
        echo '{"ok":false,"error":"download failed"}'
    fi
    exit 0
fi

[ -z "$Q" ] && echo '{"apps":[],"query":"","error":"q required"}' && exit 0

QENC=$(printf '%s' "$Q" | sed 's/ /%20/g; s/&/%26/g')
HTML=$(wget -q -T 15 -O - "https://search.f-droid.org/?q=$QENC" 2>/dev/null)

FIRST=1
printf '{"query":"%s","apps":[' "$Q"
printf '%s' "$HTML" | grep -oE '/(en/)?packages/[a-zA-Z0-9._]+' \
    | sed 's|^/en/packages/||; s|^/packages/||; s|^/||' | sort -u | head -12 \
| while read -r pkg; do
    [ $FIRST -eq 1 ] || printf ','
    FIRST=0
    printf '{"packageName":"%s"}' "$pkg"
done
printf ']}'
