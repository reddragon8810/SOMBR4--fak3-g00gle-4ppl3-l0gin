# Starbucks Captive Portal — Raspberry Pi (guida "da zero a funzionante")

Demo didattica di un captive portal su Raspberry Pi, con un secondo mestiere
utile: **lo stesso Pi puo' fare da Pi-hole a casa**.

**Solo per ambienti controllati e con consenso.**

## I due mestieri (un solo Pi)

| Mestiere | Quando | Cosa gira |
|---|---|---|
| **campo** | niente cavo ethernet | il Pi si aggancia a un **hotspot WPA2** (tuo) e crea la sua rete AP col portale |
| **casa** | cavo ethernet collegato | il Pi e' un normale **Pi-hole** (blocca la pubblicita' per la rete di casa) |

I due mestieri vogliono la stessa **rubrica internet** (porta 53) e la stessa
**porta web** (80). Se partono insieme, uno non parte. Per questo c'e' un
interruttore:

```bash
sudo starbucks-mode campo     # portale acceso, Pi-hole spento
sudo starbucks-mode casa      # Pi-hole acceso, portale spento
sudo starbucks-mode auto      # cavo = casa, niente cavo = campo
sudo starbucks-mode status    # chi sta usando porte e servizi adesso
```

All'avvio la scelta e' **automatica** (`starbucks-mode-auto.service`).

## Come funziona "campo" (il ripetitore intelligente)

```
        hotspot tuo (WPA2)  =  "Rete 1"          Pi = ripetitore
   telefono  ─┐                                     ┌─ wlan0 (STA) -> hotspot
              ├─►  rete del Pi "Rete 2"  ──►  [ R A S P B E R R Y   P I ]
   laptop   ─┘        (ap0, SSID Starbucks_Free_WiFi)  └─ ap0 (AP) -> portale
```

1. Il Pi si collega all'hotspot come farebbe un telefono (uplink).
2. Con la **stessa** antenna crea la sua rete (SSID `Starbucks_Free_WiFi`).
3. `dnsmasq` risponde a ogni dominio con l'IP del Pi: qualunque URL apre il portale.
4. Al login il client viene sbloccato (`iptables`) e **il suo DNS smette di essere
   dirottato**: da quel momento gli indirizzi si risolvono davvero e il telefono
   esce su "Rete 1".

> **Una sola antenna**: il Pi deve stare sulla **stessa banda e canale**
> dell'hotspot (2.4 o 5 GHz, lo sceglie `setup.sh`), e la velocita' si dimezza
> mentre i telefoni navigano.

Cosa gira sul Pi, in campo:

| Componente | Ruolo |
|---|---|
| `hostapd` | crea l'AP `ap0` (rete del Pi, canale = canale dell'uplink) |
| `dnsmasq-portal` | DHCP + DNS su `ap0`: ogni dominio risolve l'IP del Pi |
| `app.js` (node) | portale sulla **porta 8080** (la 80 la tiene Pi-hole quando e' in casa) |
| `iptables` | NAT verso l'hotspot, redirect 80 -> 8080, catena `PORTAL_CLIENTS` (default DROP) e `PORTAL_DNS` |
| `portal-passthrough.timer` | ogni 60s controlla se l'hotspot ci tiene ancora bloccati |

## Requisiti

- Raspberry Pi **3B+**, 4 o 5 con Raspberry Pi OS **Bookworm** (Lite basta) — chip
  CYW43455: AP+STA sulla stessa radio. Con **1 GB di RAM** (3B+) il solo portale
  e' comodo; se ci tieni acceso anche Pi-hole, tieni le liste pubblicita' piccole.
- SD da almeno 16 GB, alimentatore ufficiale.
- Un **hotspot WPA2 tuo** (router o telefono) per l'uplink di campo.
- Un laptop per SSH, un telefono per la demo.

## Installazione passo-passo

### 1. Flash del sistema

1. Raspberry Pi Imager -> **Raspberry Pi OS Lite (64-bit)**.
2. Prima di scrivere: ingranaggio -> **Enable SSH** + utente/password.
3. Avvia il Pi, trova l'IP e collega:

   ```bash
   ssh pi@<ip-del-pi>
   ```

### 2. Preparazione

```bash
sudo raspi-config          # Localisation -> Wireless LAN Country: imposta il tuo paese
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

### 3. Copia il progetto sul Pi

```bash
rsync -av --exclude node_modules --exclude .git ./ pi@<ip-del-pi>:/opt/starbucks-portal/
```

### 4. Lancia il setup

```bash
cd /opt/starbucks-portal
sudo PORTAL_UPLINK_PSK="password-del-tuo-hotspot" bash pi-portal/setup.sh
```

Lo script: installa hostapd/dnsmasq/iptables, crea il profilo uplink
(NetworkManager o wpa_supplicant), rileva canale e banda dell'hotspot, scrive le
config in posti separati (il portale **non** usa `/etc/dnsmasq.d/`, cosi' Pi-hole
non eredita mai il dirottamento), installa `starbucks-mode` e sceglie la modalita'
iniziale.

Variabili principali:

| Variabile | Default | Cosa fa |
|---|---|---|
| `PORTAL_UPLINK_PSK` | (vuoto) | password WPA2 dell'hotspot uplink (vuoto = rete aperta) |
| `PORTAL_SSID` | `Starbucks_Free_WiFi` | SSID della rete AP del Pi |
| `PORTAL_STA_SSID` | `= PORTAL_SSID` | SSID dell'hotspot a cui il Pi si aggancia |
| `PORTAL_UPSTREAM_SSID` | `= PORTAL_STA_SSID` | come si chiama la "Rete 1" nella schermata finale |
| `PORTAL_CHANNEL` | `auto` | canale AP (auto = canale dell'hotspot) |
| `PORTAL_IP` / `PORTAL_SUBNET` | `10.3.0.1` / `10.3.0.0/24` | indirizzo e subnet dell'AP |
| `PORTAL_UPSTREAM_DNS` | `1.1.1.1,8.8.8.8` | DNS pubblico annunciato ai client (usato **dopo** il login) |
| `PORTAL_WPA_PASSPHRASE` | (vuoto) | se impostata, l'AP del Pi e' WPA2 invece che aperto |
| `PORTAL_WEB_PORT` | `8080` | porta dell'app (la 80 resta a Pi-hole) |
| `PORTAL_INITIAL_MODE` | `auto` | modalita' iniziale: `auto`, `campo`, `casa` |

### 5. Avvia la demo

1. Accendi l'hotspot `PORTAL_STA_SSID`.
2. ```bash
   sudo starbucks-mode campo
   ```
3. Collega il telefono alla rete `Starbucks_Free_WiFi`: si apre il portale.
4. Login con un account @gmail.com: il telefono viene sbloccato e naviga davvero.
5. Guarda le credenziali su `http://10.3.0.1/sombra` (login `sombr4` / `sombr4`) e in
   `cat /opt/starbucks-portal/instance/creds.txt`.

Per tornare a Pi-hole a casa: collega il cavo e `sudo starbucks-mode casa`.

## Pi-hole sullo stesso Pi (guardrail)

- **Non avviare mai i due insieme**: `starbucks-mode` tiene acceso uno solo.
- Quando qualcosa non va, **prima guarda**: `sudo starbucks-doctor`.
- **Il portale non scrive piu' in `/etc/dnsmasq.d/`**: la sua config vive in
  `/etc/dnsmasq-portal.conf` e viene letta da `dnsmasq-portal.service` con
  `dnsmasq -C`. Cosi' il `address=/#/` del portale non dirotta mai il DNS di casa
  (con Pi-hole **v5**, che legge `/etc/dnsmasq.d/`, era un rischio concreto).
- Il portale ascolta sulla **8080**; Pi-hole resta sulla **80**.
- Il dnsmasq di sistema (`dnsmasq.service`) viene disattivato dal setup: la 53 e'
  di `dnsmasq-portal` in campo e di `pihole-FTL` in casa.
- Con Pi-hole **v6** la config sta in `/etc/pihole/pihole.toml` e
  `/etc/dnsmasq.d/` e' ignorato di default: va bene, il portale non ne ha bisogno.

## Se davvero ti colleghi a una rete altrui con portale

Con il **tuo** hotspot non serve. Se invece usi la WiFi libera di altri e quella
ha un suo portale, il Pi resta senza internet finche' non lo superi a mano:
segui [instruction.md](instruction.md).

## Test

```bash
npm test                                            # gating: client bloccato vs sbloccato
sudo bash pi-portal/tests/gating-iptables.test.sh   # le stesse regole su iptables vero (sul Pi)
```

`npm test` avvia l'app in un processo figlio con un finto `iptables` che registra
i comandi invece di eseguirli: simula **due client**, uno che resta bloccato e uno
che fa login, e verifica il redirect (`302` vs `204`), `/grant-status`, le
credenziali salvate e le regole di sblocco (firewall + DNS). Non serve root e non
tocca nessuna rete.

Lo script con `sudo` verifica invece le regole su **iptables vero**, in catene
usa-e-getta (`TEST_PORTAL_*`) che poi rimuove: controlla che il client bloccato
non abbia ACCEPT, che dopo il login abbia ACCEPT e `RETURN` sul DNS, e che quel
`RETURN` venga **prima** del REDIRECT. Le regole di sblocco non sono riscritte a
mano: le genera lo stesso `lib/gating.js` usato dall'app.

## Aggiornare l'app dopo una modifica al repo

```bash
cd /opt/starbucks-portal
rsync -av --exclude node_modules --exclude .git ./ pi@<ip-del-pi>:/opt/starbucks-portal/
ssh pi@<ip-del-pi> "cd /opt/starbucks-portal && npm install --omit=dev && sudo starbucks-mode campo"
```

## Comandi utili sul Pi

```bash
sudo starbucks-doctor                           # diagnosi guidata: cosa e' rotto e come sistemarlo
sudo starbucks-mode status                      # chi sta facendo cosa
systemctl status starbucks-portal hostapd-portal dnsmasq-portal create-ap0
systemctl status pihole-FTL                     # in modalita' casa
journalctl -u starbucks-portal -f               # log del portale
journalctl -u portal-passthrough                # stato del portale esterno
iptables -L PORTAL_CLIENTS -n --line-numbers    # client bloccati/sbloccati
iptables -t nat -L PORTAL_DNS -n                # chi ha DNS reale (RETURN)
cat /opt/starbucks-portal/instance/creds.txt    # log credenziali (JSON lines)
cat /tmp/portal-blocked 2>/dev/null             # presente = rete esterna ci blocca
cat /tmp/portal-url 2>/dev/null                # URL del portale esterno, se rilevato
nmcli connection show portal-uplink             # profilo dell'hotspot
```

## Troubleshooting (cause probabili con stima percentuale)

> Prima di scervellarti: `sudo starbucks-doctor` controlla ap0, le porte, il
> firewall e l'uplink, e per ogni problema stampa il comando per sistemarlo.

**Il telefono non vede la rete AP**
- hostapd non attivo (35%) — `systemctl status hostapd-portal`; `journalctl -u hostapd-portal`
- `ap0` non creato / senza IP (20%) — `ip addr show ap0`; deve avere `10.3.0.1`
- banda/canale diversi da quelli dell'hotspot (15%) — l'AP deve stare sulla stessa banda: `sudo starbucks-mode campo` e ricontrolla i log del setup
- paese regolatorio non impostato (15%) — `raspi-config` -> Wireless LAN Country
- telefono che non aggiorna la lista reti (10%) — disattiva/riattiva il WiFi
- altro (5%)

**La rete appare ma il portale non si apre**
- `dnsmasq-portal` non gira (40%) — `journalctl -u dnsmasq-portal`; `dig @10.3.0.1 example.com`
- l'app non risponde (25%) — `curl -sI http://10.3.0.1/`; `journalctl -u starbucks-portal`
- redirect 80 -> 8080 mancante (15%) — `iptables -t nat -L PREROUTING -n | grep 8080`
- cache del captive check sul telefono (10%) — prova `http://neverssl.com`
- altro (10%)

**Login completato ma niente internet sul telefono**
- il DNS resta dirottato (35%) — `iptables -t nat -L PORTAL_DNS -n` deve mostrare un `RETURN` per l'IP del telefono
- regola ACCEPT non inserita (25%) — `iptables -L PORTAL_CLIENTS -n`; verifica `PORTAL_GRANT=1` in `/etc/starbucks-portal.env`
- l'hotspot non ha davvero internet (20%) — prova dal Pi: `curl -s -o /dev/null -w '%{http_code}' http://connectivitycheck.gstatic.com/generate_204`
- NAT mancante (10%) — `iptables -t nat -L POSTROUTING -n`
- DNS pubblico bloccato dall'hotspot (10%) — cambia `PORTAL_UPSTREAM_DNS`

**`starbucks-mode casa` lascia casa senza DNS**
- Pi-hole non parte perche' la 53 e' occupata (60%) — `sudo lsof -i :53`; deve restare solo `pihole-FTL`
- i servizi del portale non si sono fermati (25%) — `sudo starbucks-mode status`
- lista pubblicita' troppo grossa per 1 GB di RAM (15%) — riduci le liste

**Le credenziali non compaiono su `/sombra`**
- app non riavviata dopo il deploy (30%) — `sudo systemctl restart starbucks-portal`
- stai guardando porta/IP sbagliati (25%) — la dashboard e' `http://10.3.0.1/sombra`
- `instance/` non scrivibile (20%) — `ls -ld /opt/starbucks-portal/instance`; chown root
- browser su host conosciuto che non passa dal portale (15%)
- altro (10%)

**Su `/sombra` i campi DEV/BROWSER/MODEL sono vuoti ("?" o "—")**
- righe di `creds.txt` scritte prima dell'aggiornamento (70%) — le nuove catture li riempiono, oppure cancella le righe vecchie e riavvia
- app non aggiornata o non riavviata (20%) — `systemctl restart starbucks-portal`
- altro (10%)

**Prestazioni pessime / rete lenta**
- canale 2.4 GHz congestionato (60%) — canale 1/6/11 meno affollato
- distanza/interferenze (25%)
- troppi client sulla stessa radio (10%)
- altro (5%)

**Dopo il deploy su Render/abisso (host con nome pubblico) il sito reindirizza a 127.0.0.1**
- `PORTAL_ENABLED=1` presente per errore anche su host (90%) — il fallback captive gira solo se il flag c'e': su un host pubblico va **rimosso** (lo scrive solo `setup.sh` sul Pi, in `/etc/starbucks-portal.env`)
- codice vecchio senza il gate `PORTAL_ENABLED` (10%) — ridistribuisci l'ultimo commit

## Nota etica e legale

Progetto **didattico**: cattura di credenziali senza consenso e' reato in quasi
tutti i paesi. Usalo solo in ambienti che controlli, con persone informate, o in
laboratori autorizzati. La versione "reale" di un captive portal deve cifrare
tutto (HTTPS) e non memorizzare password in chiaro: qui le password in chiaro
sono **volutamente** parte della demo.
