#!/usr/bin/env bash
# Verifica se l'uplink (l'hotspot a cui il Pi si aggancia) ha Internet oppure e'
# ancora bloccato dal captive portal di quella rete.
#
# - scrive /tmp/portal-blocked quando siamo bloccati (marker letto da /grant-status)
# - scrive /tmp/portal-url con l'URL del portale esterno, cosi' l'operatore lo sa
#   (con il TUO hotspot WPA2 questo caso non capita quasi mai)
# - cancella entrambi quando l'uplink torna libero
set -u

UP_IFACE="${PORTAL_UPLINK:-wlan0}"
GW="$(ip route show dev "$UP_IFACE" 2>/dev/null | awk '/default/ {print $3; exit}')"
CODE="$(curl -s --max-time 6 -o /dev/null -w '%{http_code}' http://connectivitycheck.gstatic.com/generate_204 2>/dev/null)"

if [ "$CODE" = "204" ]; then
  if [ -f /tmp/portal-blocked ]; then
    rm -f /tmp/portal-blocked
    logger -t portal-passthrough "uplink $UP_IFACE ok (204)"
  fi
  rm -f /tmp/portal-url
  exit 0
fi

touch /tmp/portal-blocked

# Prova a scoprire l'URL del portale esterno (ultimo redirect di una richiesta HTTP)
URL="$(curl -sL --max-time 6 -o /dev/null -w '%{url_effective}' http://neverssl.com 2>/dev/null)"
if [ -n "$URL" ]; then
  printf '%s\n' "$URL" > /tmp/portal-url
fi

logger -t portal-passthrough "captive portal esterno attivo (if=$UP_IFACE gw=${GW:-?} url=${URL:-?}) - serve un login manuale: vedi /opt/starbucks-portal/pi-portal/instruction.md"
