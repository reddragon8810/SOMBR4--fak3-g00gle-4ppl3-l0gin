#!/usr/bin/env bash
#
# starbucks-doctor - diagnosi rapida del Pi (captive portal + Pi-hole).
#
# Non cambia niente: guarda lo stato e, per ogni problema, stampa il comando
# per sistemarlo. Va lanciato con sudo per vedere anche iptables e i processi.
#
#   sudo starbucks-doctor          # tutto (portale + Pi-hole)
#   sudo starbucks-doctor --portale
#   sudo starbucks-doctor --casa
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
APP_DIR="${PORTAL_APP_DIR:-/opt/starbucks-portal}"
DNSMASQ_CONF=/etc/dnsmasq-portal.conf

TARGET="${1:-all}"

# ---------- output ----------
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_DIM=$'\033[2m'; C_OFF=$'\033[0m'
else
  C_OK=; C_WARN=; C_FAIL=; C_DIM=; C_OFF=
fi

FAILS=0
WARNS=0
declare -a TODO_LIST=()

section() { printf '\n%s== %s ==%s\n' "$C_DIM" "$1" "$C_OFF"; }
ok()      { printf '  %s[ OK ]%s %s\n' "$C_OK" "$C_OFF" "$1"; }
info()    { printf '  %s[INFO]%s %s\n' "$C_DIM" "$C_OFF" "$1"; }
warn()    { printf '  %s[WARN]%s %s\n' "$C_WARN" "$C_OFF" "$1"; WARNS=$((WARNS + 1)); [ -n "${2:-}" ] && TODO_LIST+=("$2"); return 0; }
fail()    { printf '  %s[FAIL]%s %s\n' "$C_FAIL" "$C_OFF" "$1"; FAILS=$((FAILS + 1)); [ -n "${2:-}" ] && TODO_LIST+=("$2"); return 0; }

have()      { command -v "$1" >/dev/null 2>&1; }
is_active() { systemctl is-active --quiet "$1" 2>/dev/null; }

# Chi sta ascoltando su una porta (sigla/indirizzo/processo), stringa vuota = libera.
port_owner() {
  local p="$1" out=""
  if have ss; then
    out="$(ss -lntup "sport = :$p" 2>/dev/null \
      | awk 'NR>1 {printf "%s/%s %s", $1, $5, ($NF ~ /users:/ ? $NF : "")}')"
  fi
  if [ -z "$out" ] && have lsof; then
    out="$(lsof -nP -iTCP:"$p" -sTCP:LISTEN 2>/dev/null | awk 'NR>1 {printf "%s ", $1}')"
  fi
  printf '%s' "$out"
}

# Il Pi ha Internet vero? (204 = si')
uplink_online() {
  [ "$(curl -s --max-time 6 -o /dev/null -w '%{http_code}' \
      http://connectivitycheck.gstatic.com/generate_204 2>/dev/null)" = "204" ]
}

check_portale() {
section "Rete del portale ($AP_IFACE)"

if ip link show "$AP_IFACE" >/dev/null 2>&1; then
  ok "$AP_IFACE esiste"
else
  fail "$AP_IFACE non esiste" "sudo starbucks-mode campo   # oppure: sudo systemctl restart create-ap0"
fi

if ip -4 addr show "$AP_IFACE" 2>/dev/null | grep -q "inet ${PORTAL_IP}/"; then
  ok "$AP_IFACE ha l'IP $PORTAL_IP"
else
  fail "$AP_IFACE non ha l'IP $PORTAL_IP" "sudo systemctl restart create-ap0"
fi

if is_active hostapd-portal.service; then
  ok "hostapd attivo"
else
  fail "hostapd-portal non attivo" "journalctl -u hostapd-portal -n 40"
fi

if is_active dnsmasq-portal.service; then
  ok "dnsmasq-portal attivo"
else
  fail "dnsmasq-portal non attivo" "journalctl -u dnsmasq-portal -n 40"
fi

section "Uplink ($STA_IFACE -> '$UPLINK_CON')"

if [ -e "/sys/class/net/$STA_IFACE" ]; then
  ok "$STA_IFACE presente"
else
  fail "$STA_IFACE assente" "sudo rfkill unblock wifi; ip link show $STA_IFACE"
fi

if have iw && iw dev "$STA_IFACE" link 2>/dev/null | grep -q "Connected"; then
  ok "$STA_IFACE collegato a un hotspot"
else
  fail "$STA_IFACE non collegato" "sudo starbucks-mode campo   # poi: nmcli con show '$UPLINK_CON'"
fi

if ip route show dev "$STA_IFACE" 2>/dev/null | grep -q '^default'; then
  ok "rotta di default presente"
else
  warn "$STA_IFACE senza rotta di default" "sudo starbucks-mode campo"
fi

if uplink_online; then
  ok "Internet dall'uplink: raggiunto (204)"
else
  if [ -f /tmp/portal-blocked ]; then
    warn "l'uplink e' bloccato da un portale esterno" "cat /tmp/portal-url 2>/dev/null; vedi pi-portal/instruction.md"
  else
    fail "nessun Internet dall'uplink" "curl -s -o /dev/null -w '%{http_code}\\n' http://connectivitycheck.gstatic.com/generate_204"
  fi
fi

section "DNS"

if [ -f "$DNSMASQ_CONF" ]; then
  if grep -q "^interface=$AP_IFACE" "$DNSMASQ_CONF"; then
    ok "$DNSMASQ_CONF presente e vincolato a $AP_IFACE"
  else
    warn "$DNSMASQ_CONF non vincolato a $AP_IFACE" "sudo starbucks-mode campo   # setup.sh riscrive la config"
  fi
else
  fail "$DNSMASQ_CONF assente" "sudo bash pi-portal/setup.sh"
fi

if [ -f /etc/dnsmasq.d/starbucks-portal.conf ]; then
  fail "residuo in /etc/dnsmasq.d (Pi-hole lo leggerebbe!)" "sudo rm -f /etc/dnsmasq.d/starbucks-portal.conf"
else
  ok "nessun residuo del portale in /etc/dnsmasq.d"
fi

if is_active dnsmasq.service; then
  fail "il dnsmasq di SISTEMA e' attivo (litiga con Pi-hole e col portale)" "sudo systemctl disable --now dnsmasq.service"
else
  ok "dnsmasq di sistema spento (bene)"
fi

if have dig; then
  resolved="$(dig +short +time=2 +tries=1 @"$PORTAL_IP" captive.example.com 2>/dev/null | head -1)"
elif have nslookup; then
  resolved="$(nslookup captive.example.com "$PORTAL_IP" 2>/dev/null | awk '/^Address: /{print $2}' | tail -1)"
else
  resolved=""
  info "ne' dig ne' nslookup installati: salto il test di risoluzione"
fi
if [ -n "$resolved" ]; then
  if [ "$resolved" = "$PORTAL_IP" ]; then
    ok "il DNS del portale risolve tutto su $PORTAL_IP"
  else
    fail "il DNS su $PORTAL_IP risponde '$resolved' invece di $PORTAL_IP" "journalctl -u dnsmasq-portal -n 40"
  fi
fi

section "Porte"

for p in 53 80 "$WEB_PORT"; do
  owner="$(port_owner "$p")"
  if [ -z "$owner" ]; then
    if [ "$p" = "80" ]; then
      ok "porta 80 libera (il portale la prende via redirect)"
    else
      fail "nessuno ascolta sulla porta $p" "sudo starbucks-mode campo"
    fi
  else
    case "$p" in
      53)  owner_l="$(printf '%s' "$owner" | tr 'A-Z' 'a-z')"
           case "$owner_l" in
             *dnsmasq*|*pihole*) ok "porta 53: $owner" ;;
             *) fail "porta 53 occupata da altro: $owner" "sudo lsof -i :53" ;;
           esac ;;
      80)  ok "porta 80: $owner (il portale usa la $WEB_PORT)";;
      *)   owner_l="$(printf '%s' "$owner" | tr 'A-Z' 'a-z')"
           case "$owner_l" in
             *node*) ok "porta $WEB_PORT: $owner" ;;
             *) warn "porta $WEB_PORT occupata da altro: $owner" "sudo lsof -i :$WEB_PORT" ;;
           esac ;;
    esac
  fi
done

section "Firewall"

if [ "$(id -u)" != 0 ]; then
  warn "serve root per leggere iptables: rilancia con sudo" "sudo starbucks-doctor"
else
  if iptables -C FORWARD -i "$AP_IFACE" -j "$CHAIN" 2>/dev/null; then
    ok "FORWARD: i client di $AP_IFACE passano da $CHAIN"
  else
    fail "manca il salto FORWARD -i $AP_IFACE -> $CHAIN" "sudo starbucks-mode campo"
  fi

  if iptables -L "$CHAIN" -n 2>/dev/null | grep -q 'DROP'; then
    ok "$CHAIN termina in DROP (i client partono bloccati)"
  else
    fail "$CHAIN senza DROP: i client sarebbero liberi prima del login" "sudo starbucks-mode campo"
  fi

  if iptables -t nat -C PREROUTING -i "$AP_IFACE" -d "$PORTAL_IP" -p tcp --dport 80 \
       -j REDIRECT --to-ports "$WEB_PORT" 2>/dev/null; then
    ok "redirect 80 -> $WEB_PORT attivo su $AP_IFACE"
  else
    fail "manca il redirect 80 -> $WEB_PORT" "sudo starbucks-mode campo"
  fi

  if iptables -t nat -C PREROUTING -i "$AP_IFACE" -p udp --dport 53 -j "$DNS_CHAIN" 2>/dev/null; then
    ok "dirottamento DNS ($DNS_CHAIN) attivo"
  else
    fail "manca il dirottamento DNS ($DNS_CHAIN)" "sudo starbucks-mode campo"
  fi

  if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "MASQUERADE.*$STA_IFACE"; then
    ok "NAT (MASQUERADE) verso $STA_IFACE"
  else
    fail "manca il MASQUERADE verso $STA_IFACE" "sudo starbucks-mode campo"
  fi

  granted="$(iptables -t nat -L "$DNS_CHAIN" -n 2>/dev/null | grep -c 'RETURN')"
  info "client sbloccati (RETURN in $DNS_CHAIN): $granted"
fi

section "Portale HTTP"

code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "http://$PORTAL_IP:$WEB_PORT/" 2>/dev/null)"
if [ "$code" = "200" ]; then
  ok "l'app risponde su http://$PORTAL_IP:$WEB_PORT/"
else
  fail "l'app non risponde su $PORTAL_IP:$WEB_PORT (codice: ${code:-000})" "journalctl -u starbucks-portal -n 40"
fi

probe="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
  -H 'Host: connectivitycheck.gstatic.com' "http://$PORTAL_IP:$WEB_PORT/generate_204" 2>/dev/null)"
if [ "$probe" = "302" ]; then
  ok "la probe captive riceve 302 (il portale si aprira')"
else
  warn "la probe captive risponde ${probe:-000} invece di 302" "verifica PORTAL_ENABLED=1 in /etc/starbucks-portal.env; sudo systemctl restart starbucks-portal"
fi

if [ -w "$APP_DIR" ] || [ -w "$APP_DIR/instance" ]; then
  ok "la cartella delle credenziali e' scrivibile"
else
  warn "$APP_DIR/instance non scrivibile: le credenziali non verranno salvate" "sudo mkdir -p $APP_DIR/instance && sudo chown -R root:root $APP_DIR"
fi
}

check_casa() {
section "Pi-hole (modalita' casa)"

if have pihole; then
  ok "Pi-hole installato ($(pihole -v 2>/dev/null | head -1 | tr -d '\n'))"
else
  warn "Pi-hole non sembra installato" "curl -sSL https://install.pi-hole.net | bash"
fi

if is_active pihole-FTL.service; then
  ok "pihole-FTL attivo"
else
  fail "pihole-FTL non attivo (vedi: journalctl -u pihole-FTL -n 40)" "sudo starbucks-mode casa"
fi

if [ -e /sys/class/net/eth0/carrier ] && [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = "1" ]; then
  ok "cavo ethernet collegato"
else
  info "nessun cavo su eth0 (normale se sei in campo)"
fi

owner53="$(port_owner 53)"
if [ -n "$owner53" ]; then
  case "$(printf '%s' "$owner53" | tr 'A-Z' 'a-z')" in
    *pihole*) ok "porta 53: $owner53" ;;
    *dnsmasq*) warn "porta 53 presa da dnsmasq (il portale?), non da Pi-hole" "sudo starbucks-mode casa" ;;
    *) warn "porta 53 occupata da altro: $owner53" "sudo lsof -i :53" ;;
  esac
else
  warn "nessuno ascolta sulla porta 53" "sudo starbucks-mode casa"
fi
}

# ---------- main ----------

echo "starbucks-doctor"
if [ -r "$ENV_FILE" ]; then
  ok "config trovata: $ENV_FILE"
else
  fail "config $ENV_FILE assente" "sudo bash pi-portal/setup.sh"
fi

mode_now="campo"
[ -e /sys/class/net/eth0/carrier ] && [ "$(cat /sys/class/net/eth0/carrier 2>/dev/null)" = "1" ] && mode_now="casa"
info "modalita' rilevata dal cavo: $mode_now"

PORTAL_ON=0; is_active starbucks-portal.service && PORTAL_ON=1
PIHOLE_ON=0; is_active pihole-FTL.service && PIHOLE_ON=1

if [ "$PORTAL_ON" = 1 ] && [ "$PIHOLE_ON" = 1 ]; then
  fail "portale E Pi-hole accesi insieme: non possono convivere" "sudo starbucks-mode $mode_now"
fi

case "$TARGET" in
  -h|--help|help)
    echo "Uso: sudo starbucks-doctor [--portale|--casa]"
    echo "  (senza argomenti controlla tutto)"
    exit 0 ;;
  --portale|portale) check_portale ;;
  --casa|casa)       check_casa ;;
  *)
    if [ "$PORTAL_ON" = 1 ]; then
      check_portale
    else
      info "portale spento: salto i controlli runtime (per forzarli: sudo starbucks-doctor --portale)"
      [ -f "$DNSMASQ_CONF" ] && ok "config del portale presente ($DNSMASQ_CONF)" || warn "config del portale assente" "sudo bash pi-portal/setup.sh"
    fi
    check_casa
    ;;
esac

# ---------- riepilogo ----------
echo
if [ "$FAILS" = 0 ] && [ "$WARNS" = 0 ]; then
  printf '%sTutto a posto.%s\n' "$C_OK" "$C_OFF"
elif [ "$FAILS" = 0 ]; then
  printf '%sNessun problema bloccante, %s avviso/i.%s\n' "$C_WARN" "$WARNS" "$C_OFF"
else
  printf '%s%s problema/i, %s avviso/i.%s\n' "$C_FAIL" "$FAILS" "$WARNS" "$C_OFF"
fi

if [ "${#TODO_LIST[@]}" -gt 0 ]; then
  echo
  echo "COSA FARE:"
  declare -A SEEN=()
  for t in "${TODO_LIST[@]}"; do
    [ -n "${SEEN[$t]:-}" ] && continue
    SEEN[$t]=1
    printf '  - %s\n' "$t"
  done
fi

[ "$FAILS" = 0 ]
