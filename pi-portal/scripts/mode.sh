#!/usr/bin/env bash
#
# starbucks-mode - sceglie il "mestiere" del Raspberry Pi.
#
#   campo (alias: field, portal)
#       Il Pi si aggancia al tuo hotspot WPA2 (Rete 1) e crea la sua rete
#       (Rete 2) con il captive portal. Pi-hole spento.
#   casa (alias: home)
#       Il Pi e' un normale Pi-hole (cavo ethernet). Portale spento.
#   auto
#       Cavo ethernet collegato -> casa, altrimenti -> campo.
#   status
#       Chi sta usando porte e servizi in questo momento.
#
# L'idea: i due mestieri vogliono la stessa rubrica internet (porta 53) e la
# stessa porta web (80). Se partono insieme uno non parte, quindi l'interruttore
# tiene acceso uno solo alla volta.
#
set -uo pipefail

ENV_FILE="${PORTAL_ENV_FILE:-/etc/starbucks-portal.env}"
if [ -r "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

AP_IFACE="${PORTAL_AP_IFACE:-ap0}"
STA_IFACE="${PORTAL_UPLINK:-wlan0}"
UPLINK_CON="${PORTAL_UPLINK_CON:-portal-uplink}"
WEB_PORT="${PORTAL_WEB_PORT:-8080}"
CHAIN="${PORTAL_CHAIN:-PORTAL_CLIENTS}"
DNS_CHAIN="${PORTAL_DNS_CHAIN:-PORTAL_DNS}"
PORTAL_IP="${PORTAL_IP:-10.3.0.1}"
NET_IFACE="${PORTAL_NET_IFACE:-$STA_IFACE}"

PORTAL_UNITS="create-ap0.service hostapd-portal.service dnsmasq-portal.service starbucks-portal.service"
PIHOLE_UNITS="${PORTAL_PIHOLE_UNITS:-pihole-FTL.service lighttpd.service}"
PASSTHROUGH_UNITS="portal-passthrough.timer portal-passthrough.service"

log()  { echo "[starbucks-mode] $*"; }
warn() { echo "[starbucks-mode] [!] $*" >&2; }

have() { command -v "$1" >/dev/null 2>&1; }

root_or_die() {
  [ "$(id -u)" = 0 ] || { echo "Serve root: sudo starbucks-mode $*" >&2; exit 1; }
}

# ---------- rilevamento ----------

detect_mode() {
  local carrier_file=/sys/class/net/eth0/carrier
  if [ -r "$carrier_file" ] && [ "$(cat "$carrier_file" 2>/dev/null)" = "1" ]; then
    echo casa
  else
    echo campo
  fi
}

nm_active() {
  have nmcli && systemctl is-active --quiet NetworkManager 2>/dev/null
}

# ---------- uplink ----------

uplink_up() {
  if nm_active; then
    if nmcli connection up "$UPLINK_CON" >/dev/null 2>&1; then
      return 0
    fi
    warn "nmcli non e' riuscito ad attivare '$UPLINK_CON' (SSID/PSK configurati?)."
    return 1
  fi
  if have wpa_supplicant && [ -f "/etc/wpa_supplicant/wpa_supplicant-${STA_IFACE}.conf" ]; then
    systemctl restart "wpa_supplicant@${STA_IFACE}.service" >/dev/null 2>&1 || true
  fi
  return 0
}

uplink_down() {
  if nm_active; then
    nmcli connection down "$UPLINK_CON" >/dev/null 2>&1 || true
  fi
}

# ---------- firewall (portale) ----------

apply_firewall() {
  sysctl -qw net.ipv4.ip_forward=1 || true
  grep -q '^net.ipv4.ip_forward=1' /etc/sysctl.conf 2>/dev/null \
    || echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf

  # NAT verso l'interfaccia con internet (l'hotspot)
  iptables -t nat -C POSTROUTING -o "$NET_IFACE" -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o "$NET_IFACE" -j MASQUERADE

  # L'app ascolta sulla 8080: i client che aprono 10.3.0.1:80 finiscono sul portale.
  # Vincolato alla destinazione PORTAL_IP, cosi' la navigazione vera (dopo il
  # login) NON viene riscritta.
  iptables -t nat -C PREROUTING -i "$AP_IFACE" -d "$PORTAL_IP" -p tcp --dport 80 \
    -j REDIRECT --to-ports "$WEB_PORT" 2>/dev/null \
    || iptables -t nat -A PREROUTING -i "$AP_IFACE" -d "$PORTAL_IP" -p tcp --dport 80 \
      -j REDIRECT --to-ports "$WEB_PORT"

  # DNS: i client non ancora sbloccati vengono dirottati sul dnsmasq del portale.
  # Chi ha fatto login riceve una regola RETURN (la aggiunge l'app) e torna a
  # risolvere davvero. Il DHCP annuncia un DNS pubblico (PORTAL_UPSTREAM_DNS).
  iptables -t nat -N "$DNS_CHAIN" 2>/dev/null || iptables -t nat -F "$DNS_CHAIN"
  iptables -t nat -A "$DNS_CHAIN" -j REDIRECT --to-ports 53
  iptables -t nat -C PREROUTING -i "$AP_IFACE" -p udp --dport 53 -j "$DNS_CHAIN" 2>/dev/null \
    || iptables -t nat -A PREROUTING -i "$AP_IFACE" -p udp --dport 53 -j "$DNS_CHAIN"
  iptables -t nat -C PREROUTING -i "$AP_IFACE" -p tcp --dport 53 -j "$DNS_CHAIN" 2>/dev/null \
    || iptables -t nat -A PREROUTING -i "$AP_IFACE" -p tcp --dport 53 -j "$DNS_CHAIN"

  # risposte di connessioni gia' stabilite: sempre permesse
  iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null \
    || iptables -I FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  # catena di gating: i client partono bloccati (DROP), l'app aggiunge ACCEPT al login
  iptables -N "$CHAIN" 2>/dev/null || iptables -F "$CHAIN"
  iptables -A "$CHAIN" -j DROP
  iptables -C FORWARD -i "$AP_IFACE" -j "$CHAIN" 2>/dev/null \
    || iptables -A FORWARD -i "$AP_IFACE" -j "$CHAIN"

  persist_firewall
}

remove_firewall() {
  iptables -t nat -D PREROUTING -i "$AP_IFACE" -d "$PORTAL_IP" -p tcp --dport 80 \
    -j REDIRECT --to-ports "$WEB_PORT" 2>/dev/null || true
  iptables -t nat -D PREROUTING -i "$AP_IFACE" -p udp --dport 53 -j "$DNS_CHAIN" 2>/dev/null || true
  iptables -t nat -D PREROUTING -i "$AP_IFACE" -p tcp --dport 53 -j "$DNS_CHAIN" 2>/dev/null || true
  iptables -t nat -F "$DNS_CHAIN" 2>/dev/null || true
  iptables -t nat -X "$DNS_CHAIN" 2>/dev/null || true

  while iptables -C FORWARD -i "$AP_IFACE" -j "$CHAIN" 2>/dev/null; do
    iptables -D FORWARD -i "$AP_IFACE" -j "$CHAIN" || break
  done
  iptables -F "$CHAIN" 2>/dev/null || true
  iptables -X "$CHAIN" 2>/dev/null || true

  while iptables -t nat -C POSTROUTING -o "$NET_IFACE" -j MASQUERADE 2>/dev/null; do
    iptables -t nat -D POSTROUTING -o "$NET_IFACE" -j MASQUERADE || break
  done

  persist_firewall
}

persist_firewall() {
  netfilter-persistent save >/dev/null 2>&1 \
    || iptables-save > /etc/iptables/rules.v4 2>/dev/null \
    || true
}

# ---------- servizi ----------

start_units() { for u in $1; do systemctl start "$u" >/dev/null 2>&1 || true; done; }
stop_units()  { for u in $1; do systemctl stop  "$u" >/dev/null 2>&1 || true; done; }

# ---------- modalita' ----------

mode_campo() {
  log "CAMPO: uplink '$STA_IFACE' -> AP '$AP_IFACE' col captive portal."
  stop_units "$PIHOLE_UNITS"
  uplink_up || true
  start_units "create-ap0.service"
  start_units "hostapd-portal.service"
  start_units "dnsmasq-portal.service"
  start_units "starbucks-portal.service"
  apply_firewall
  systemctl start portal-passthrough.timer >/dev/null 2>&1 || true
  log "Portale pronto: http://$PORTAL_IP/ (dashboard /sombra) - i client escono da $NET_IFACE."
}

mode_casa() {
  log "CASA: Pi-hole attivo, portale spento."
  systemctl stop $PASSTHROUGH_UNITS >/dev/null 2>&1 || true
  stop_units "$PORTAL_UNITS"
  # lascia libera la WiFi: NetworkManager torna a gestire wlan0 per la rete di casa
  uplink_down
  remove_firewall
  # Mai lasciare la config del portale dove Pi-hole la leggerebbe.
  rm -f /etc/dnsmasq.d/starbucks-portal.conf 2>/dev/null || true
  start_units "$PIHOLE_UNITS"
  log "Pi-hole attivo. Per la demo: sudo starbucks-mode campo"
}

mode_status() {
  local m eth
  m="$(detect_mode)"
  eth="$(cat /sys/class/net/eth0/carrier 2>/dev/null || echo n/a)"
  echo "starbucks-mode"
  echo "  rilevato      : $m (eth0 carrier: $eth)"
  echo "  uplink        : $STA_IFACE ($([ "$m" = campo ] && echo "connesso a '$UPLINK_CON'" || echo disattivato))"
  echo "  AP            : $AP_IFACE $(
    ip -4 addr show "$AP_IFACE" 2>/dev/null | awk '/inet /{print $2; exit}' || true
  )"
  echo "  servizi:"
  for u in $PORTAL_UNITS $PIHOLE_UNITS; do
    printf '    %-26s %s\n' "$u" "$(systemctl is-active "$u" 2>/dev/null || echo sconosciuto)"
  done
  if have ss; then
    echo "  in ascolto (53 / 80 / $WEB_PORT):"
    ss -lntup 2>/dev/null \
      | awk -v w="$WEB_PORT" '$4 ~ /:53$/ || $4 ~ /:80$/ || $4 ~ ":" w "$" {print "    " $1 " " $4 " " $6}'
  fi
  echo "  catena $CHAIN:"
  iptables -L "$CHAIN" -n --line-numbers 2>/dev/null | sed 's/^/    /' || echo "    assente (serve root?)"
}

# ---------- main ----------

main() {
  local m
  case "${1:-status}" in
    campo|field|portal)
      root_or_die "$1"; mode_campo ;;
    casa|home)
      root_or_die "$1"; mode_casa ;;
    auto)
      root_or_die auto
      m="$(detect_mode)"
      log "auto: rilevato '$m'"
      case "$m" in
        casa) mode_casa ;;
        *)    mode_campo ;;
      esac ;;
    status|"")
      mode_status ;;
    *)
      echo "Uso: starbucks-mode {campo|casa|auto|status}" >&2
      exit 2 ;;
  esac
}

# Esegui main solo se lo script e' stato chiamato direttamente. Se invece viene
# "sourced" (per esempio dai test che riusano apply_firewall/remove_firewall)
# non fa nulla.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
