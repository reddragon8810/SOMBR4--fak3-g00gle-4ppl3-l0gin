#!/usr/bin/env bash
#
# Verifica il gating su iptables VERO: serve root e iptables (cioè il Pi).
# Usa catene e nomi usa-e-getta (TEST_PORTAL_*) e le pulisce sempre, quindi non
# tocca la configurazione vera. Le regole di sblocco non sono scritte a mano:
# vengono generate da lib/gating.js, la stessa fonte che usa l'app, cosi' il test
# non puo' "restare indietro" rispetto al codice.
#
#   sudo bash pi-portal/tests/gating-iptables.test.sh
#
set -uo pipefail

if [ "$(id -u)" != 0 ]; then
  echo "SKIP: serve root  ->  sudo bash pi-portal/tests/gating-iptables.test.sh"
  exit 0
fi
if ! command -v iptables >/dev/null 2>&1; then
  echo "SKIP: iptables non installato"
  exit 0
fi
if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node non installato (serve per generare le regole di sblocco)"
  exit 0
fi

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATING_JS="$TESTS_DIR/../../lib/gating.js"

# --- parametri usa-e-getta -----------------------------------------------
export PORTAL_ENV_FILE="/dev/null"
export PORTAL_CHAIN="TEST_PORTAL_CLIENTS"
export PORTAL_DNS_CHAIN="TEST_PORTAL_DNS"
export PORTAL_AP_IFACE="lo"          # non creiamo interfacce vere
export PORTAL_NET_IFACE="lo"
export PORTAL_IP="10.99.0.1"         # IP finto: nessun traffico reale lo usa
export PORTAL_WEB_PORT="65534"
CLIENT="10.99.0.9"                   # il client che verra' sbloccato
OTHER="10.99.0.99"                   # un client che resta bloccato

# shellcheck disable=SC1090
. "$TESTS_DIR/../scripts/mode.sh"

# I test NON devono salvare le regole di prova nel firewall persistente.
persist_firewall() { return 0; }

PASS=0
FAIL=0
ok()      { echo "  [ OK ] $1"; PASS=$((PASS + 1)); }
ko()      { echo "  [FAIL] $1"; FAIL=$((FAIL + 1)); }
chk()     { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$d"; else ko "$d"; fi; }
chk_not() { local d="$1"; shift; if "$@" >/dev/null 2>&1; then ko "$d"; else ok "$d"; fi; }
chk_pipe() { local d="$1" cmd="$2"; if bash -c "$cmd" >/dev/null 2>&1; then ok "$d"; else ko "$d"; fi }

# Applica le regole di sblocco generate da lib/gating.js per un client.
unlock_client() {
  local client="$1" line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local -a parts
    IFS=$'\t' read -r -a parts <<<"$line"
    iptables "${parts[@]}"
  done < <(node -e \
    'const {grantRules}=require(process.argv[1]);for(const r of grantRules(process.argv[2],process.argv[3],process.argv[4]))console.log(r.join("\t"));' \
    "$GATING_JS" "$client" "$PORTAL_CHAIN" "$PORTAL_DNS_CHAIN")
}

cleanup() {
  remove_firewall >/dev/null 2>&1 || true
  iptables -D FORWARD -i lo -j "$PORTAL_CHAIN" 2>/dev/null || true
  iptables -F "$PORTAL_CHAIN" 2>/dev/null || true
  iptables -X "$PORTAL_CHAIN" 2>/dev/null || true
  iptables -t nat -F "$PORTAL_DNS_CHAIN" 2>/dev/null || true
  iptables -t nat -X "$PORTAL_DNS_CHAIN" 2>/dev/null || true
  iptables -t nat -D PREROUTING -i lo -p udp --dport 53 -j "$PORTAL_DNS_CHAIN" 2>/dev/null || true
  iptables -t nat -D PREROUTING -i lo -p tcp --dport 53 -j "$PORTAL_DNS_CHAIN" 2>/dev/null || true
  iptables -t nat -D PREROUTING -i lo -d "$PORTAL_IP" -p tcp --dport 80 \
    -j REDIRECT --to-ports "$PORTAL_WEB_PORT" 2>/dev/null || true
  iptables -t nat -D POSTROUTING -o lo -j MASQUERADE 2>/dev/null || true
}
trap cleanup EXIT

echo "starbucks-gating-test (iptables reale, catene di prova)"
echo
echo "== 1. il firewall del portale viene applicato =="
cleanup
apply_firewall

chk     "il traffico da lo passa dalla catena di gating" iptables -C FORWARD -i lo -j "$PORTAL_CHAIN"
chk_pipe "di default i client sono bloccati (DROP)" "iptables -L '$PORTAL_CHAIN' -n | grep -q DROP"
chk_pipe "il DNS e' dirottato di default (REDIRECT)" "iptables -t nat -L '$PORTAL_DNS_CHAIN' -n | grep -q REDIRECT"
chk     "redirect 80 -> $PORTAL_WEB_PORT attivo" \
        iptables -t nat -C PREROUTING -i lo -d "$PORTAL_IP" -p tcp --dport 80 -j REDIRECT --to-ports "$PORTAL_WEB_PORT"
chk_pipe "NAT (MASQUERADE) configurato" "iptables -t nat -S POSTROUTING | grep -q MASQUERADE"

echo
echo "== 2. il client bloccato =="
chk_not "non ha un ACCEPT nella catena di gating" iptables -C "$PORTAL_CHAIN" -s "$CLIENT" -j ACCEPT
chk_not "il suo DNS non ha un RETURN (viene dirottato)" iptables -t nat -C "$PORTAL_DNS_CHAIN" -s "$CLIENT" -j RETURN

echo
echo "== 3. il login lo sblocca (regole da lib/gating.js) =="
unlock_client "$CLIENT"

chk     "ora ha un ACCEPT" iptables -C "$PORTAL_CHAIN" -s "$CLIENT" -j ACCEPT
chk_not "il DROP per lui e' stato tolto" iptables -C "$PORTAL_CHAIN" -s "$CLIENT" -j DROP
chk     "il suo DNS ha un RETURN (smette di essere dirottato)" iptables -t nat -C "$PORTAL_DNS_CHAIN" -s "$CLIENT" -j RETURN

ret_line="$(iptables -t nat -L "$PORTAL_DNS_CHAIN" -n --line-numbers | awk -v ip="$CLIENT" '$0 ~ ip && /RETURN/ {print $1; exit}')"
red_line="$(iptables -t nat -L "$PORTAL_DNS_CHAIN" -n --line-numbers | awk '/REDIRECT/ {print $1; exit}')"
if [ -n "$ret_line" ] && [ -n "$red_line" ] && [ "$ret_line" -lt "$red_line" ]; then
  ok "il RETURN viene PRIMA del REDIRECT (ordine corretto: $ret_line < $red_line)"
else
  ko "ordine sbagliato: RETURN=$ret_line REDIRECT=$red_line (il DNS resterebbe dirottato)"
fi

echo
echo "== 4. gli altri client non sono toccati =="
chk_not "un altro client resta bloccato" iptables -C "$PORTAL_CHAIN" -s "$OTHER" -j ACCEPT
chk_not "un altro client resta col DNS dirottato" iptables -t nat -C "$PORTAL_DNS_CHAIN" -s "$OTHER" -j RETURN

echo
echo "== 5. rimuovendo il firewall si torna puliti =="
remove_firewall
chk_not "la catena di gating non e' piu' raggiungibile" iptables -C FORWARD -i lo -j "$PORTAL_CHAIN"
chk_not "il dirottamento DNS e' stato tolto" iptables -t nat -C PREROUTING -i lo -p udp --dport 53 -j "$PORTAL_DNS_CHAIN"

echo
echo "-------------------------------------------------------------------"
echo "  $PASS ok, $FAIL falliti"
echo "  (nota: apply_firewall abilita net.ipv4.ip_forward=1, che serve al"
echo "   portale vero; le regole di prova sono state tutte rimosse)"
echo "-------------------------------------------------------------------"

[ "$FAIL" = 0 ]
