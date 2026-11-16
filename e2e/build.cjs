'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const platform = require('./lib/platform.cjs');

const ROOT = path.resolve(__dirname, '..');
const APPS = { admin: 'admin_dashboard', mobile: process.env.E2E_MOBILE_DIR || 'flutter_mobile_app' };
const only = process.env.E2E_APP;
const edition = process.env.E2E_EDITION || 'advanced';
const firebaseTarget = process.env.E2E_FIREBASE_TARGET || 'supermarket';
if (edition !== 'basic' && edition !== 'advanced') {
  console.error(`E2E_EDITION must be basic or advanced, got "${edition}"`);
  process.exit(1);
}
const tenantRouting = process.env.E2E_TENANT_ROUTING === '1';
const adminTarget = process.env.E2E_ADMIN_TARGET;
const adminBuildDir = process.env.E2E_ADMIN_BUILD || (tenantRouting ? 'web_e2e_v4' : 'web_e2e');
const editionBuildDir = process.env.E2E_MOBILE_BUILD || `${edition === 'basic' ? 'web_e2e_basic' : 'web_e2e'}${tenantRouting ? '_v4' : ''}`;

for (const [key, dir] of Object.entries(APPS)) {
  if (only && only !== key) continue;
  if (key === 'admin' && !only && edition === 'basic'
      && fs.existsSync(path.join(ROOT, dir, 'build', adminBuildDir, 'index.html'))) {
    console.log('\n== skipping admin_dashboard: one build serves every edition ==');
    continue;
  }
  const cwd = path.resolve(ROOT, dir);
  const outputName = key === 'admin' ? adminBuildDir : editionBuildDir;
  const emulatorDefines = [
    'USE_FIREBASE_EMULATOR=true',
    'FIREBASE_EMULATOR_HOST=127.0.0.1',
    `FIRESTORE_EMULATOR_PORT=${process.env.FIRESTORE_EMULATOR_PORT || 8089}`,
    `FIREBASE_AUTH_EMULATOR_PORT=${process.env.FIREBASE_AUTH_EMULATOR_PORT || 9099}`,
  ];
  const appDefines = key === 'admin'
    ? [
      `PLATFORM_PUBLIC_KEYS=${platform.publicKeysText(platform.ensureKey())}`,
      `PLATFORM_API_URL=${platform.PLATFORM_API_URL}`,
    ]
    : [
      'COPILOT_URL=http://127.0.0.1:18765',
      'FORECAST_API=http://127.0.0.1:18766',
      `PLATFORM_API_URL=${platform.PLATFORM_API_URL}`,
      `FIREBASE_TARGET=${firebaseTarget}`,
      `EDITION=${edition}`,
      ...(tenantRouting ? [
        `COMPANY_LOOKUP_URL=${platform.PLATFORM_API_URL}/v1/companies`,
        `COMPANY_REGISTRY_KEYS=${platform.publicKeysText(platform.ensureKey())}`,
      ] : []),
    ];
  const safeDefines = [...emulatorDefines, ...appDefines];
  console.log(`\n== building ${dir} ==`);
  const run = (args) => {
    const r = spawnSync('flutter', args, { cwd, stdio: 'inherit', shell: process.platform === 'win32', windowsHide: true });
    if (r.status !== 0) process.exit(r.status || 1);
  };
  run(['pub', 'get']);
  run([
    'build', 'web', `--${process.env.E2E_BUILD_MODE || 'release'}`, '--no-web-resources-cdn',
    ...(key === 'admin' && adminTarget ? ['-t', adminTarget] : []),
    ...safeDefines.map((define) => `--dart-define=${define}`),
    '--output', `build/${outputName}`,
  ]);

  const manifestArgs = [
    path.join(ROOT, 'scripts', 'release_manifest.py'),
    '--repo-root', ROOT,
    '--build-dir', path.resolve(cwd, 'build', outputName),
    '--platform', 'web',
    '--firebase-target', key === 'admin' ? 'runtime' : firebaseTarget,
    '--app', key,
    '--app-dir', cwd,
    '--edition', key === 'admin' ? 'runtime' : edition,
  ];
  for (const define of safeDefines) manifestArgs.push('--define', define);
  const manifest = spawnSync(platform.PYTHON, manifestArgs, {
    cwd: ROOT,
    stdio: 'inherit',
    shell: false,
    windowsHide: true,
  });
  if (manifest.error) console.error(`Could not generate release manifest: ${manifest.error.message}`);
  if (manifest.status !== 0) process.exit(manifest.status || 1);
}
