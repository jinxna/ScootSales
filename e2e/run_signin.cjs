'use strict';

const platformProject = require('./lib/platform_api.cjs').PLATFORM_PROJECT;

if (process.env.GCLOUD_PROJECT !== platformProject) {
  console.error(`Start the emulators for ${platformProject}: firebase emulators:exec --only firestore,auth --project ${platformProject} --config admin_dashboard/firebase.json "node e2e/run_signin.cjs"`);
  process.exit(1);
}
delete process.env.GCLOUD_PROJECT;
process.env.E2E_RUNNER = 'signin';
require('./run.cjs');
