const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const test = require('node:test');

const {
  assertDevOnlyMode,
  createServer,
  isAllowedOrigin,
  resolveBindHost,
  resolveStaticPath,
} = require('../server');

async function withServer(callback) {
  const server = createServer({ acknowledged: true });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  try {
    const address = server.address();
    await callback(`http://127.0.0.1:${address.port}`);
  } finally {
    await new Promise((resolve, reject) =>
      server.close((error) => (error ? reject(error) : resolve())),
    );
  }
}

test('uses an exact origin allowlist', () => {
  assert.equal(isAllowedOrigin('http://localhost:5000'), true);
  assert.equal(isAllowedOrigin('https://cos40005.web.app'), false);
  assert.equal(isAllowedOrigin('http://localhost:61234'), false);
  assert.equal(isAllowedOrigin('https://example.invalid'), false);
});

test('binds loopback by default and only opts into 0.0.0.0 explicitly', () => {
  assert.equal(resolveBindHost({}), '127.0.0.1');
  assert.equal(resolveBindHost({ OTP_BIND_HOST: '' }), '127.0.0.1');
  assert.equal(resolveBindHost({ OTP_BIND_HOST: '0.0.0.0' }), '0.0.0.0');
});

test('keeps static file paths inside the Flutter web directory', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'fyp-a-static-'));
  const webDir = path.join(root, 'web');
  fs.mkdirSync(webDir);
  try {
    assert.equal(
      resolveStaticPath('/assets/app.js', webDir),
      path.resolve(webDir, 'assets', 'app.js'),
    );
    assert.equal(resolveStaticPath('/../server.js', webDir), null);
    assert.equal(resolveStaticPath('/%2e%2e/server.js', webDir), null);
    assert.equal(resolveStaticPath('/..%5cserver.js', webDir), null);
    assert.equal(resolveStaticPath('/%E0%A4%A', webDir), null);
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});

test('refuses to act as a production server', () => {
  assert.doesNotThrow(
    () => assertDevOnlyMode('development', 'dev-mailpit', true),
  );
  assert.throws(
    () => assertDevOnlyMode('production', 'dev-mailpit', true),
    /dev-only/,
  );
  assert.throws(
    () => assertDevOnlyMode('development', 'production', true),
    /dev-only/,
  );
  assert.throws(
    () => assertDevOnlyMode('development', 'dev-mailpit', false),
    /dev-only/,
  );
});

test('answers allowed OPTIONS preflight with bounded CORS headers', async () => {
  await withServer(async (baseUrl) => {
    const response = await fetch(`${baseUrl}/api/health`, {
      method: 'OPTIONS',
      headers: {
        Origin: 'http://localhost:5000',
        'Access-Control-Request-Method': 'GET',
        'Access-Control-Request-Headers': 'Authorization, Content-Type',
      },
    });

    assert.equal(response.status, 204);
    assert.equal(
      response.headers.get('access-control-allow-origin'),
      'http://localhost:5000',
    );
    assert.equal(
      response.headers.get('access-control-allow-methods'),
      'GET, POST, OPTIONS',
    );
    assert.equal(
      response.headers.get('access-control-allow-headers'),
      'Content-Type, Authorization',
    );
    assert.equal(
      response.headers.get('access-control-allow-credentials'),
      null,
    );
  });
});

test('rejects disallowed browser origins before handling the API', async () => {
  await withServer(async (baseUrl) => {
    const response = await fetch(`${baseUrl}/api/health`, {
      headers: { Origin: 'https://example.invalid' },
    });

    assert.equal(response.status, 403);
    assert.equal(response.headers.get('access-control-allow-origin'), null);
  });
});

test('health response identifies the development mode', async () => {
  await withServer(async (baseUrl) => {
    const response = await fetch(`${baseUrl}/api/health`, {
      headers: { Origin: 'http://localhost:5000' },
    });
    const payload = await response.json();

    assert.equal(response.status, 200);
    assert.equal(payload.status, 'ok');
    assert.equal(payload.mode, 'dev-mailpit');
  });
});
