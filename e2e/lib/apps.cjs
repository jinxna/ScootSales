'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const platform = require('./platform.cjs');

const REPO = path.resolve(__dirname, '..', '..');
const tenantRouting = process.env.E2E_TENANT_ROUTING === '1';
const BUILD = `${process.env.E2E_EDITION === 'basic' ? 'web_e2e_basic' : 'web_e2e'}${tenantRouting ? '_v4' : ''}`;
const APPS = {
  admin: { dir: path.join(REPO, 'admin_dashboard', 'build', process.env.E2E_ADMIN_BUILD || (tenantRouting ? 'web_e2e_v4' : 'web_e2e')), label: 'admin dashboard' },
  mobile: { dir: path.join(path.resolve(REPO, process.env.E2E_MOBILE_DIR || 'flutter_mobile_app'), 'build', process.env.E2E_MOBILE_BUILD || BUILD), label: 'mobile app' },
};

const MIME = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.png': 'image/png', '.jpg': 'image/jpeg', '.gif': 'image/gif',
  '.svg': 'image/svg+xml', '.wasm': 'application/wasm', '.ico': 'image/x-icon',
  '.ttf': 'font/ttf', '.otf': 'font/otf', '.woff2': 'font/woff2',
};

function serve(buildDir, fixed = {}) {
  const root = path.resolve(buildDir);
  const server = http.createServer((req, res) => {
    const url = decodeURIComponent(req.url.split('?')[0]);
    if (Object.hasOwn(fixed, url)) {
      res.writeHead(200, { 'Content-Type': MIME['.json'], 'Cache-Control': 'no-store' });
      return res.end(fixed[url]);
    }
    let file = path.join(root, url);
    if (!file.startsWith(root) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) {
      file = path.join(root, 'index.html');
    }
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    fs.createReadStream(file).pipe(res);
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve(server)));
}

async function startApps() {
  const servers = {};
  const urls = {};
  const workspaceEnvelope = platform.harnessWorkspaceEnvelope();
  for (const [name, app] of Object.entries(APPS)) {
    if (!fs.existsSync(path.join(app.dir, 'index.html'))) {
      throw new Error(`${app.label} build missing at ${app.dir}; run \`npm run e2e:build\` first`);
    }
    const fixed = name === 'admin' ? { '/workspace.json': JSON.stringify(workspaceEnvelope) } : {};
    servers[name] = await serve(app.dir, fixed);
    urls[name] = `http://127.0.0.1:${servers[name].address().port}`;
  }
  return { urls, close: () => Promise.all(Object.values(servers).map((s) => new Promise((r) => s.close(r)))) };
}

module.exports = { APPS, startApps };
