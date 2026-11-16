const http = require('http');
const fs = require('fs');
const path = require('path');

const PORT        = parseInt(process.env.PORT        || '8080');
function resolveBindHost(env = process.env) {
  return env.OTP_BIND_HOST || '127.0.0.1';
}
const HOST        = resolveBindHost();
const OTP_MODE    = process.env.OTP_MODE    || 'dev-mailpit';
const NODE_ENV    = process.env.NODE_ENV    || 'development';
const DEFAULT_ALLOWED_ORIGINS = [
  'http://localhost:3000',
  'http://localhost:5000',
  'http://localhost:8080',
  'http://127.0.0.1:3000',
  'http://127.0.0.1:5000',
  'http://127.0.0.1:8080',
];
const configuredOrigins =
  process.env.CORS_ALLOWED_ORIGINS || process.env.OTP_ALLOWED_ORIGINS || '';
const ALLOWED_ORIGINS = new Set((configuredOrigins || DEFAULT_ALLOWED_ORIGINS.join(','))
  .split(',')
  .map((value) => value.trim())
  .filter(Boolean));
const WEB_DIR     = path.join(__dirname, 'admin_dashboard', 'build', 'web');

function assertDevOnlyMode(
  nodeEnv = NODE_ENV,
  otpMode = OTP_MODE,
  acknowledged = process.env.OTP_DEV_ACKNOWLEDGED === '1',
) {
  if (
    nodeEnv === 'production'
    || otpMode !== 'dev-mailpit'
    || !acknowledged
  ) {
    throw new Error(
      'The bundled static server is dev-only. Set OTP_DEV_ACKNOWLEDGED=1 for '
      + 'local use. Serve production builds from the reverse proxy.',
    );
  }
}

function isAllowedOrigin(origin) {
  if (!origin) return true;
  return ALLOWED_ORIGINS.has(origin);
}

function applyCorsHeaders(req, res) {
  const origin = req.headers.origin;
  if (origin && isAllowedOrigin(origin)) {
    res.setHeader('Access-Control-Allow-Origin', origin);
    res.setHeader('Vary', 'Origin');
  }
  res.setHeader('Access-Control-Allow-Methods', 'GET, POST, OPTIONS');
  res.setHeader('Access-Control-Allow-Headers', 'Content-Type, Authorization');
}

async function handleApi(req, res, body) {
  const url      = new URL(req.url, `http://${req.headers.host}`);
  const pathname = url.pathname;

  res.setHeader('Content-Type', 'application/json');
  const origin = req.headers.origin;
  applyCorsHeaders(req, res);

  if (req.method === 'OPTIONS') {
    if (!isAllowedOrigin(origin)) {
      res.writeHead(403);
      res.end(JSON.stringify({ success: false, message: 'Origin not allowed.' }));
      return;
    }
    res.writeHead(204);
    res.end();
    return;
  }

  if (!isAllowedOrigin(origin)) {
    res.writeHead(403);
    res.end(JSON.stringify({ success: false, message: 'Origin not allowed.' }));
    return;
  }

  if (pathname === '/api/health' && req.method === 'GET') {
    res.writeHead(200);
    res.end(JSON.stringify({ status: 'ok', mode: OTP_MODE }));
    return;
  }

  res.writeHead(404);
  res.end(JSON.stringify({ success: false, message: 'Not found.' }));
}

const MIME_TYPES = {
  '.html': 'text/html',
  '.js':   'application/javascript',
  '.css':  'text/css',
  '.json': 'application/json',
  '.png':  'image/png',
  '.jpg':  'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif':  'image/gif',
  '.svg':  'image/svg+xml',
  '.ico':  'image/x-icon',
  '.woff': 'font/woff',
  '.woff2':'font/woff2',
  '.ttf':  'font/ttf',
  '.otf':  'font/otf',
  '.wasm': 'application/wasm',
};

function resolveStaticPath(urlPath, webDir = WEB_DIR) {
  const root = path.resolve(webDir);
  let decodedPath;
  try {
    decodedPath = decodeURIComponent((urlPath || '/').split('?')[0]);
  } catch {
    return null;
  }
  if (decodedPath.includes('\0')) return null;

  const relativeUrlPath = decodedPath.replace(/^[/\\]+/, '');
  const candidate = path.resolve(root, relativeUrlPath);
  const relativeToRoot = path.relative(root, candidate);
  if (
    relativeToRoot.startsWith('..')
    || path.isAbsolute(relativeToRoot)
  ) {
    return null;
  }
  return candidate;
}

const CSP_DIRECTIVES = [
  "default-src 'self'",
  "script-src 'self' 'wasm-unsafe-eval' https://www.gstatic.com https://apis.google.com",
  "style-src 'self' 'unsafe-inline'",
  "img-src 'self' data: blob: https:",
  "font-src 'self' data: https://fonts.gstatic.com",
  "connect-src 'self' https://*.googleapis.com https://www.gstatic.com https://fonts.gstatic.com",
  "frame-src https://*.firebaseapp.com",
  "worker-src 'self' blob:",
  "base-uri 'self'",
  "object-src 'none'",
  "form-action 'self'",
].join('; ');

const SECURITY_HEADERS = {
  'X-Content-Type-Options': 'nosniff',
  'X-Frame-Options': 'DENY',
  'Referrer-Policy': 'strict-origin-when-cross-origin',
  'Permissions-Policy': 'geolocation=(), microphone=(self), camera=()',
  'Content-Security-Policy-Report-Only': CSP_DIRECTIVES,
};

function applySecurityHeaders(req, res) {
  for (const [name, value] of Object.entries(SECURITY_HEADERS)) {
    res.setHeader(name, value);
  }
  if ((req.url || '').startsWith('/api/')) {
    res.setHeader('Cache-Control', 'no-store');
  }
}

function createServer(options = {}) {
  assertDevOnlyMode(
    options.nodeEnv,
    options.otpMode,
    options.acknowledged,
  );
  return http.createServer(async (req, res) => {
    applySecurityHeaders(req, res);
    const urlPath = req.url.split('?')[0];

    if (urlPath.startsWith('/api/')) {
      let body = '';
      req.on('data', (chunk) => { body += chunk; });
      req.on('end', () => handleApi(req, res, body));
      return;
    }

    if (urlPath === '/workspace.json') {
      const recordPath = process.env.WORKSPACE_JSON || path.join(WEB_DIR, 'workspace.json');
      fs.readFile(recordPath, (err, data) => {
        res.writeHead(err ? 404 : 200, {
          'Content-Type': 'application/json',
          'Cache-Control': 'no-cache',
        });
        res.end(err ? '{"detail":"No company record."}' : data);
      });
      return;
    }

    let filePath = resolveStaticPath(urlPath);
    if (!filePath) {
      res.writeHead(403);
      res.end('Forbidden');
      return;
    }
    if (fs.existsSync(filePath) && fs.statSync(filePath).isDirectory()) {
      filePath = path.join(filePath, 'index.html');
    }
    if (!fs.existsSync(filePath)) {
      filePath = path.join(WEB_DIR, 'index.html');
    }
    const ext         = path.extname(filePath);
    const contentType = MIME_TYPES[ext] || 'application/octet-stream';
    fs.readFile(filePath, (err, data) => {
      if (err) {
        res.writeHead(500);
        res.end('Internal Server Error');
        return;
      }
      res.writeHead(200, { 'Content-Type': contentType });
      res.end(data);
    });
  });
}

if (require.main === module) {
  createServer().listen(PORT, HOST, () => {
    console.log(`DEV-ONLY static server running at http://${HOST}:${PORT}`);
    console.log('Do not deploy this process to production.');
  });
}

module.exports = {
  assertDevOnlyMode,
  createServer,
  isAllowedOrigin,
  resolveBindHost,
  resolveStaticPath,
};
