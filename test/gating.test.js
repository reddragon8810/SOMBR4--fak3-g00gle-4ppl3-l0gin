'use strict';

// Test del "gating" del portale: simula due client diversi sulla rete del Pi e
// verifica che PRIMA del login siano dirottati sul portale e DOPO il login
// ricevano il 204 (portale chiuso) e le regole giuste per il DNS.
//
// Avvia `node app.js` come processo figlio su una porta libera: non tocca reti
// reali e non serve root. Sul PATH del figlio mette un finto `iptables` che
// registra i comandi invece di eseguirli (dove il finto binario e' eseguibile:
// su Windows non lo e', e quei controlli vengono saltati automaticamente).
// L'unica cosa che tocca e' instance/creds.txt (ripristinato alla fine).

const { before, after, test } = require('node:test');
const assert = require('node:assert/strict');
const { execFile, spawn } = require('node:child_process');
const fs = require('node:fs');
const http = require('node:http');
const net = require('node:net');
const os = require('node:os');
const path = require('node:path');

const { grantRules } = require('../lib/gating');

const ROOT = path.resolve(__dirname, '..');
const CREDS_FILE = path.join(ROOT, 'instance', 'creds.txt');

// Due client finti sulla rete del portale (10.3.0.0/24), distinti via
// X-Forwarded-For: l'app ha `trust proxy 1`, quindi req.ip e' quello.
const CLIENT_BLOCKED = '10.3.0.50'; // non fa mai login
const CLIENT_LOGGED = '10.3.0.51';  // fa login -> sbloccato

const BUTTON_HOST = 'connectivitycheck.gstatic.com';
const PORTAL_BASE = 'http://10.3.0.1';
const EMAIL = 'gating.test@gmail.com';

let child = null;
let port = 0;
let stubDir = '';
let stubLog = '';
let stubUsable = false;
let childStderr = '';
let credsExisted = false;
let credsBackup = null;

// ---------- helpers ----------

function freePort() {
  return new Promise((resolve, reject) => {
    const srv = net.createServer();
    srv.on('error', reject);
    srv.listen(0, '127.0.0.1', () => {
      const p = srv.address().port;
      srv.close(() => resolve(p));
    });
  });
}

// Una richiesta HTTP verso l'app, con Host finto (come fa il telefono quando
// chiede connectivitycheck.gstatic.com) e X-Forwarded-For per scegliere il client.
function request(pathname, { host, client, method = 'GET', form } = {}) {
  return new Promise((resolve, reject) => {
    const headers = {};
    if (host) headers.Host = host;
    if (client) headers['X-Forwarded-For'] = client;

    let body = null;
    if (form) {
      body = new URLSearchParams(form).toString();
      headers['Content-Type'] = 'application/x-www-form-urlencoded';
      headers['Content-Length'] = Buffer.byteLength(body);
    }

    const req = http.request({ host: '127.0.0.1', port, path: pathname, method, headers }, res => {
      let data = '';
      res.on('data', c => { data += c; });
      res.on('end', () => resolve({
        status: res.statusCode,
        location: res.headers.location,
        body: data
      }));
    });
    req.on('error', reject);
    if (body) req.write(body);
    req.end();
  });
}

// La probe captive, come la manda Android/iPhone prima di aprire il portale.
function captiveProbe(client) {
  return request('/generate_204', { host: BUTTON_HOST, client });
}

function stubCommands() {
  try {
    return fs.readFileSync(stubLog, 'utf8').split('\n').map(s => s.trim()).filter(Boolean);
  } catch (e) {
    return [];
  }
}

const stubEnv = () => ({ ...process.env, PATH: stubDir + path.delimiter + process.env.PATH });

// Il finto binario e' uno script con shebang: eseguibile su Linux/macOS, non su
// Windows. Lo scopriamo una volta sola, cosi' quei controlli si saltano da soli.
function stubWorks() {
  return new Promise(resolve => {
    execFile('iptables', ['--stub-selftest'], { env: stubEnv() }, err => {
      resolve(!err && stubCommands().includes('--stub-selftest'));
    });
  });
}

async function waitFor(predicate, timeoutMs = 4000) {
  const start = Date.now();
  for (;;) {
    const value = predicate();
    if (value) return value;
    if (Date.now() - start > timeoutMs) return null;
    await new Promise(r => setTimeout(r, 50));
  }
}

async function waitForServer(timeoutMs = 15000) {
  const start = Date.now();
  for (;;) {
    try {
      await request('/', { host: '127.0.0.1', client: CLIENT_BLOCKED });
      return;
    } catch (e) { /* non ancora su */ }
    if (Date.now() - start > timeoutMs) {
      throw new Error('app.js non si e\' avviato.\n' + childStderr);
    }
    await new Promise(r => setTimeout(r, 100));
  }
}

// ---------- setup / teardown ----------

before(async () => {
  port = await freePort();

  stubDir = fs.mkdtempSync(path.join(os.tmpdir(), 'stub-iptables-'));
  stubLog = path.join(stubDir, 'commands.log');
  fs.writeFileSync(
    path.join(stubDir, 'iptables'),
    `#!/usr/bin/env bash\nprintf '%s\\n' "$*" >> ${JSON.stringify(stubLog)}\nexit 0\n`,
    { mode: 0o755 }
  );

  stubUsable = await stubWorks();
  fs.writeFileSync(stubLog, ''); // butta il self-test

  credsExisted = fs.existsSync(CREDS_FILE);
  credsBackup = credsExisted ? fs.readFileSync(CREDS_FILE) : null;

  child = spawn(process.execPath, ['app.js'], {
    cwd: ROOT,
    env: {
      ...process.env,
      PORT: String(port),
      PORTAL_ENABLED: '1',
      PORTAL_GRANT: '1',
      PORTAL_CHAIN: 'TEST_CLIENTS',
      PORTAL_DNS_CHAIN: 'TEST_DNS',
      PORTAL_HOSTS: '127.0.0.1',
      PORTAL_REDIRECT_BASE: PORTAL_BASE,
      PORTAL_SSID: 'Starbucks_Free_WiFi',
      PORTAL_UPSTREAM_SSID: 'Rete 1',
      PATH: stubDir + path.delimiter + process.env.PATH
    },
    stdio: ['ignore', 'ignore', 'pipe']
  });
  child.stderr.on('data', chunk => { childStderr += chunk; });

  await waitForServer();
});

after(async () => {
  if (child && child.exitCode === null) {
    child.kill();
    await new Promise(r => {
      const t = setTimeout(r, 2000);
      child.once('exit', () => { clearTimeout(t); r(); });
    });
    if (child.exitCode === null) child.kill('SIGKILL');
  }

  // Ripristina le credenziali com'erano prima del test.
  try {
    if (credsExisted) fs.writeFileSync(CREDS_FILE, credsBackup);
    else if (fs.existsSync(CREDS_FILE)) fs.rmSync(CREDS_FILE);
  } catch (e) { /* niente di grave */ }

  if (stubDir) fs.rmSync(stubDir, { recursive: true, force: true });
});

// ---------- il client bloccato ----------

test('client bloccato: qualunque URL viene dirottato sul portale (302)', async () => {
  const res = await captiveProbe(CLIENT_BLOCKED);
  assert.equal(res.status, 302);
  assert.equal(res.location, PORTAL_BASE + '/');
});

test('client bloccato: gli host locali non vengono toccati (la pagina si apre)', async () => {
  const res = await request('/', { host: '127.0.0.1', client: CLIENT_BLOCKED });
  assert.equal(res.status, 200);
});

test('prima del login /grant-status dice "non sbloccato"', async () => {
  const res = await request('/grant-status', { host: '127.0.0.1', client: CLIENT_LOGGED });
  const data = JSON.parse(res.body);
  assert.equal(data.grantEnabled, true);
  assert.equal(data.granted, false);
  assert.equal(data.ip, CLIENT_LOGGED);
});

// ---------- il login ----------

test('il login risponde con la schermata finale e sblocca il client', async () => {
  const res = await request('/login', {
    host: '127.0.0.1',
    client: CLIENT_LOGGED,
    method: 'POST',
    form: { email: EMAIL, password: 'password123' }
  });
  assert.equal(res.status, 302);
  assert.equal(res.location, '/close');

  const status = JSON.parse((await request('/grant-status', { host: '127.0.0.1', client: CLIENT_LOGGED })).body);
  assert.equal(status.granted, true, 'dopo il login il client deve risultare sbloccato');
});

test('le regole emesse sono esattamente quelle attese (firewall + DNS)', async (t) => {
  if (!stubUsable) {
    return t.skip('finto iptables non eseguibile in questo ambiente (Windows)');
  }

  const done = await waitFor(
    () => stubCommands().includes(`-t nat -I TEST_DNS -s ${CLIENT_LOGGED} -j RETURN`)
  );
  assert.ok(done, 'l\'app deve inserire la regola DNS di sblocco');

  const commands = stubCommands();
  assert.ok(
    commands.includes(`-D TEST_CLIENTS -s ${CLIENT_LOGGED} -j DROP`),
    'toglie il blocco dalla catena di gating'
  );
  assert.ok(
    commands.includes(`-I TEST_CLIENTS -s ${CLIENT_LOGGED} -j ACCEPT`),
    'consente il traffico del client sbloccato'
  );
  assert.ok(
    !commands.some(c => c.includes(CLIENT_BLOCKED)),
    'il client che non ha fatto login non deve essere toccato'
  );
});

// ---------- il dopo-login ----------

test('dopo il login il client sbloccato chiude il portale (204)', async () => {
  const res = await captiveProbe(CLIENT_LOGGED);
  assert.equal(res.status, 204);
});

test('l\'altro client resta bloccato: il gating vale per singolo IP', async () => {
  const res = await captiveProbe(CLIENT_BLOCKED);
  assert.equal(res.status, 302);
  assert.equal(res.location, PORTAL_BASE + '/');
});

test('/grant-status distingue i due client', async () => {
  const blocked = JSON.parse((await request('/grant-status', { host: '127.0.0.1', client: CLIENT_BLOCKED })).body);
  const logged = JSON.parse((await request('/grant-status', { host: '127.0.0.1', client: CLIENT_LOGGED })).body);
  assert.equal(blocked.granted, false);
  assert.equal(logged.granted, true);
  assert.equal(logged.uplinkOnline, true);
});

test('la schermata finale mostra il passaggio Rete 2 -> Rete 1', async () => {
  const res = await request('/close', { host: '127.0.0.1', client: CLIENT_LOGGED });
  assert.equal(res.status, 200);
  assert.match(res.body, /Connected to <b>Starbucks_Free_WiFi<\/b>/);
  assert.match(res.body, /Connected to <b>Rete 1<\/b>/);
});

test('le credenziali del login finiscono nel log su disco', async () => {
  const lines = fs.readFileSync(CREDS_FILE, 'utf8').trim().split('\n').filter(Boolean);
  const last = JSON.parse(lines[lines.length - 1]);
  assert.equal(last.email, EMAIL);
  assert.equal(last.ip, CLIENT_LOGGED);
});

// ---------- il contratto delle regole ----------

test('le regole di sblocco restano in un solo posto (lib/gating.js)', () => {
  assert.deepEqual(grantRules('10.0.0.9', 'C', 'D'), [
    ['-D', 'C', '-s', '10.0.0.9', '-j', 'DROP'],
    ['-I', 'C', '-s', '10.0.0.9', '-j', 'ACCEPT'],
    ['-t', 'nat', '-D', 'D', '-s', '10.0.0.9', '-j', 'RETURN'],
    ['-t', 'nat', '-I', 'D', '-s', '10.0.0.9', '-j', 'RETURN']
  ]);
});
