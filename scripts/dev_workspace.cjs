'use strict';

const fs = require('node:fs');
const platform = require('../e2e/lib/platform.cjs');

const PROJECTS = { supermarket: 'cos40005', hardware: 'hardware-client-sales' };
const FORECASTING_URL = 'http://127.0.0.1:8000';

const [client = 'supermarket', edition = 'advanced', out] = process.argv.slice(2);
const project = PROJECTS[client];
if (!project || !['advanced', 'basic'].includes(edition) || !out) {
  console.error('usage: node scripts/dev_workspace.cjs <supermarket|hardware> <advanced|basic> <out-file>');
  process.exit(2);
}

const key = platform.ensureKey('dev-local');
const record = {
  ...platform.baseRecord(project),
  status: 'active',
  planRef: edition === 'basic' ? 'P1' : 'P2',
  edition,
  services: client === 'supermarket' ? { forecastingUrl: FORECASTING_URL } : {},
};
fs.writeFileSync(out, JSON.stringify(platform.signRecord(record, key)));
process.stdout.write(platform.publicKeysText(key));
