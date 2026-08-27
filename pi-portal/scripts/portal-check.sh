#!/usr/bin/env bash
# Verifica se l'uplink STA (wlan0) ha Internet oppure e' ancora bloccato dal
# captive portal del router. In caso di blocco scrive un marker e logga le
# istruzioni (vedi pi-portal/instruction.md).
set -u

GW="$(ip route show dev wlan0 2>/dev/null | awk '/default/ {print $3; exit}')"
CODE="$(curl -s --max-time 6 -o /dev/null -w '%{http_code}' http://connectivitycheck.gstatic.com/generate_204 2>/dev/null)"

if [ "$CODE" = "204" ]; then
  if [ -f /tmp/portal-blocked ]; then
    rm -f /tmp/portal-blocked
    logger -t portal-passthrough "uplink STA ok (204)"
  fi
  exit 0
fi

touch /tmp/portal-blocked
logger -t portal-passthrough "captive portal del router attivo (gw=${GW:-?}) - completa il login manuale: vedi /opt/starbucks-portal/pi-portal/instruction.md"
