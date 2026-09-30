its just a game.
i wanted to learn coding so dont take it as a real tool

```bash
npm install
npm test        # simula un client bloccato e uno sbloccato e controlla il gating
npm start       # http://localhost:3000
```

---

## Sul Raspberry Pi (demo captive portal)

La cartella [`pi-portal/`](pi-portal/README.md) rende il Pi un **ripetitore
intelligente**: si aggancia a un hotspot WPA2 e crea la sua rete con il portale
di login. Lo stesso Pi puo' anche fare da **Pi-hole** a casa (col cavo ethernet):
i due mestieri si scambiano con un solo comando.

```bash
sudo starbucks-mode campo     # portale acceso, Pi-hole spento
sudo starbucks-mode casa      # Pi-hole acceso, portale spento
sudo starbucks-mode auto      # cavo = casa, niente cavo = campo
sudo starbucks-mode status    # cosa sta usando porte e servizi
```

Guida completa (installazione, Pi-hole, troubleshooting):
[`pi-portal/README.md`](pi-portal/README.md).
