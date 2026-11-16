'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const E = require('../lib/emulator.cjs');

async function showDoneSteps(page) {
  const toggle = B.semantic(page, /^Show \d+ done$/);
  if (await toggle.count()) await toggle.click();
}

async function predictionRegression(t, session) {
  E.requireEmulators();
  const productId = 'e2e_prediction_point';
  await t.db.put('products', productId, {
    productId, productName: 'E2E forecast point', status: 'active',
  });
  const cases = [
    { name: 'zero', point: 0, usable: true, restock: false },
    { name: 'string-zero', point: '0', usable: true, restock: false },
    { name: 'alias-zero', predictedQuantity: 0, usable: true, restock: false },
    { name: 'positive', point: 120, usable: true, restock: true },
    { name: 'missing', usable: false },
    { name: 'null', point: null, usable: false },
    { name: 'invalid', point: 'invalid', usable: false },
    { name: 'negative', point: -1, usable: false },
    { name: 'negative-with-alias', point: -1, predictedQuantity: 120, usable: false },
    { name: 'nan', point: 'NaN', usable: false },
    { name: 'infinity', point: 'Infinity', usable: false },
    { name: 'negative-infinity', point: '-Infinity', usable: false },
    { name: 'observed-only', quantity: 120, usable: false },
    { name: 'insufficient', status: 'insufficient_history', point: 120, usable: false, inForecastFilter: false },
    { name: 'stale', status: 'stale', point: 120, usable: false, inForecastFilter: false },
    { name: 'legacy-positive', status: '', predictedQuantity: 120, usable: true, restock: true },
    { name: 'legacy-zero', status: '', predictedQuantity: 0, usable: false, inForecastFilter: false },
    { name: 'legacy-invalid-point', status: '', point: 'invalid', predictedQuantity: 120, usable: false },
  ];
  const evidence = { flow: 'prediction-point', scope: 'local emulators only', cases: [] };
  await admin.goToPage(session.page, 'Demand Forecast');
  for (const fixture of cases) {
    await t.step(`prediction ${fixture.name}: display, filter and restock eligibility`, async () => {
      const productName = `E2E forecast ${fixture.name}`;
      const { name, usable, restock, inForecastFilter = true, ...fields } = fixture;
      await t.db.put('demand_forecasts', productId, {
        productId, productName, status: 'ok', forecastMonth: '2026-10',
        periodStart: '2026-10-05', dataCutoff: '2026-10-04',
        generatedAt: new Date().toISOString(), componentCount: 1,
        modelledComponentCount: 1, model: 'aggregate', referenceUnits: 10,
        recommendedAction: 'Increase stock', ...fields,
      });
      await session.page.getByRole('button', { name: 'Reload forecasts', exact: true }).click();
      await B.see(session.page, productName);
      const point = fields.point ?? fields.predictedQuantity;
      const quantityText = (text) => B.semantic(session.page,
        new RegExp(`(?:^|\\s)${text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}(?:$|\\s)`));
      if (usable) {
        await quantityText(`${point} units`).waitFor({ state: 'attached', timeout: 20000 });
        await B.see(session.page, '1 of 1 outlet series forecast');
        assert.equal(await B.semantic(session.page, 'Observed only · 10 units/week').count(), 0);
      } else {
        await B.see(session.page, 'Observed only · 10 units/week');
        assert.equal(await B.semantic(session.page, '1 of 1 outlet series forecast').count(), 0);
        for (const invalid of ['0 units', '-1 units', 'null units', 'NaN units', 'Infinity units', 'invalid units', '120 units']) {
          assert.equal(await quantityText(invalid).count(), 0, `${name} displayed ${invalid}`);
        }
      }
      await admin.pickDropdown(session.page, 'All catalogue products', 'With a forecast');
      await B.see(session.page, inForecastFilter ? productName : 'No forecasts for this filter');
      await admin.pickDropdown(session.page, 'With a forecast', 'All catalogue products');
      await session.page.getByRole('tab', { name: /Restock Recommendations/ }).click();
      await B.see(session.page, restock ? productName : 'No restock recommendation for this filter');
      if (['zero', 'positive', 'invalid'].includes(name)) await t.shot(session, `prediction-${name}-restock`);
      await session.page.getByRole('tab', { name: /Forecast Overview/ }).click();
      await B.see(session.page, productName);
      if (['zero', 'positive', 'invalid'].includes(name)) await t.shot(session, `prediction-${name}-overview`);
      evidence.cases.push({ name, usable, restock: !!restock, inForecastFilter });
    });
  }
  const output = path.join(E.OUTPUT_DIR, 'dashboard_setup');
  fs.mkdirSync(output, { recursive: true });
  fs.writeFileSync(path.join(output, 'prediction-result.json'),
    JSON.stringify({ ...evidence, passed: true }, null, 2));
}

module.exports = {
  name: 'dashboard_setup',
  predictionRegression,
  async run(t) {
    const { db, accounts, seed } = t;
    let session;
    let repairTargetUid;
    const evidence = { flow: 'dashboard_setup', checks: [] };

    await t.step('account scan is read-only until a safe repair is confirmed', async () => {
      E.requireEmulators();
      assert.ok(await db.get('branches', 'B1'), 'expected the seeded B1 branch');

      const repairTarget = {
        email: 'e2e.repair.target@example.test',
        name: 'E2E Repair Target',
        code: 'BM-REPAIR-E2E',
      };
      ({ uid: repairTargetUid } = await db.ensureUser(repairTarget.email, repairTarget.name));
      await db.put('users', repairTarget.email, {
        uid: repairTargetUid,
        userUid: repairTargetUid,
        name: repairTarget.name,
        email: repairTarget.email,
        role: 'branch_manager',
        user_group: 'branch_manager',
        status: 'active',
        employeeCode: repairTarget.code,
        userId: repairTarget.code,
        branchId: 'B1',
        branch_id: 'B1',
      });
      assert.equal(await db.get('user_access', repairTargetUid), null,
        'repair fixture must start without a user_access record');

      const supervisorProfile = await db.get('users', accounts.supervisor.email);
      const supervisorAccess = await db.get('user_access', seed.uids.supervisor);
      assert.ok(supervisorProfile && supervisorAccess,
        'base supervisor profile and access record must exist');
      await db.put('users', accounts.supervisor.email, {
        ...supervisorProfile,
        assignedSalesmanCodes: ['S001', 'MISSING-E2E'],
      });
      await db.put('user_access', seed.uids.supervisor, {
        ...supervisorAccess,
        assignedSalesmanCodes: ['S001', 'MISSING-E2E'],
      });

      session = await t.session('admin');
      await B.loginAdmin(session.page, session.url, accounts.admin.email);
      await admin.waitForShell(session.page);
      await admin.goToPage(session.page, 'Role Assignment');
      await session.page.getByRole('button', { name: /Account repair tools/ }).first().click();
      await B.scrollIntoView(session.page, B.semantic(session.page, 'Repair accounts'));
      await B.see(session.page, 'Scan saved account profiles and access records. No data changes until you confirm a repair.');
      await session.page.getByRole('button', { name: 'Scan accounts', exact: true }).click();
      await B.see(session.page, 'Scan complete');
      assert.equal(await db.get('user_access', repairTargetUid), null,
        'read-only scan wrote an access record before confirmation');
      assert.deepEqual((await db.get('users', accounts.supervisor.email)).assignedSalesmanCodes,
        ['S001', 'MISSING-E2E'], 'read-only scan changed supervisor profile codes');
      assert.deepEqual((await db.get('user_access', seed.uids.supervisor)).assignedSalesmanCodes,
        ['S001', 'MISSING-E2E'], 'read-only scan changed supervisor access codes');
      const missingAccessCard = session.page.locator(
        `[flt-semantics-identifier="account-repair-missingAccess-${repairTarget.email}-${repairTargetUid}"]`,
      );
      const staleSupervisorCodeCard = session.page.locator(
        `[flt-semantics-identifier="account-repair-invalidSupervisorCode-${accounts.supervisor.email}-MISSING-E2E"]`,
      );
      await B.scrollIntoView(session.page, missingAccessCard);
      await B.see(session.page, 'Account profile is missing an access record');
      await B.see(session.page, repairTarget.email);
      await B.see(session.page, 'Invite this person again from the invitations list.');
      assert.equal(await missingAccessCard.getByRole('button', { name: 'Confirm repair', exact: true }).count(), 0,
        'missing-access finding must not offer a repair that creates an access record');
      await B.scrollIntoView(session.page, staleSupervisorCodeCard);
      await B.see(session.page, 'Supervisor has a missing salesman code');
      await B.see(session.page, 'MISSING-E2E');
      assert.equal(await staleSupervisorCodeCard.getByRole('button', { name: 'Confirm repair', exact: true }).count(), 1,
        'stale supervisor-code finding should expose its own confirmed repair');
      evidence.checks.push('read-only scan reports the missing access record without writing');
      await t.shot(session, 'account-repair-scan-read-only');

      await staleSupervisorCodeCard.getByRole('button', { name: 'Confirm repair', exact: true }).click();
      await B.see(session.page, 'Repair this account record?');
      await B.see(session.page, 'The current documents will be read again.');
      await session.page.getByRole('button', { name: 'Repair', exact: true }).click();
      const repairedSupervisorProfile = await db.waitForDoc(
        'users', accounts.supervisor.email,
        (data) => JSON.stringify(data.assignedSalesmanCodes) === JSON.stringify(['S001']),
        { label: 'stale supervisor profile code removal' },
      );
      const repairedSupervisorAccess = await db.waitForDoc(
        'user_access', seed.uids.supervisor,
        (data) => JSON.stringify(data.assignedSalesmanCodes) === JSON.stringify(['S001']),
        { label: 'stale supervisor access code removal' },
      );
      assert.deepEqual(repairedSupervisorProfile.assignedSalesmanCodes, ['S001']);
      assert.deepEqual(repairedSupervisorAccess.assignedSalesmanCodes, ['S001']);
      await B.see(session.page, 'Account profile is missing an access record');
      evidence.checks.push('confirmed stale supervisor-code repair preserves S001 in both mirrors');
      await t.shot(session, 'account-repair-stale-supervisor-code');

      await B.scrollIntoView(session.page, missingAccessCard);
      await B.see(session.page, 'Invite this person again from the invitations list.');
      assert.equal(await db.get('user_access', repairTargetUid), null,
        'a repair created an access record for the profile that must be invited again');
      evidence.checks.push('missing access record is listed with "invite again" and never created by the repair');
      await t.shot(session, 'account-repair-confirmed');
    });

    await t.step('repair scan blocks conflicting identities and preserves real supervisor assignments', async () => {
      E.requireEmulators();
      const fixtures = [
        ['round2-role-uid', { role: 'salesman', status: 'active', branchId: 'B1' }],
        ['ROUND2-ROLE', { uid: 'round2-role-uid', role: 'admin', status: 'active', employeeCode: 'ROUND2-ROLE', branchId: 'B1' }],
        ['round2-suspended-uid', { role: 'supervisor', status: 'suspended', branchId: 'B1' }],
        ['ROUND2-SUSPENDED', { uid: 'round2-suspended-uid', role: 'supervisor', status: 'active', employeeCode: 'ROUND2-SUSPENDED', branchId: 'B1' }],
        ['ROUND2-CAP', { uid: 'round2-cap-uid', role: 'supervisor', status: 'active', employeeCode: 'ROUND2-CAP', branchId: 'B1', assignedSalesmanCodes: ['R1', 'R2', 'R3', 'R4', 'R5', 'R6'] }],
        ['ROUND2-SUP', { uid: 'round2-supervisor-uid', role: 'supervisor', status: 'active', employeeCode: 'ROUND2-SUP', branchId: 'B1', assignedSalesmanCodes: ['ROUND2-SALE'] }],
        ['ROUND2-SALE', { uid: 'round2-salesman-uid', role: 'salesman', status: 'active', employeeCode: 'ROUND2-SALE', branchId: 'B1', supervisorUid: 'round2-supervisor-uid', supervisor_uid: 'round2-supervisor-uid', supervisorId: 'ROUND2-SUP', supervisor_id: 'ROUND2-SUP' }],
      ];
      for (const [id, data] of fixtures) await db.put('users', id, data);
      await db.put('user_access', 'round2-salesman-uid', {
        ...fixtures.at(-1)[1], accessVersion: 2, userDocId: 'ROUND2-SALE',
      });
      await B.scrollIntoView(session.page, B.semantic(session.page, 'Repair accounts'),
        { step: -300, bottomInset: 0 });
      await session.page.getByRole('button', { name: 'Scan accounts', exact: true }).click();
      await B.see(session.page, 'Scan complete');
      for (const [recordId, uid] of [
        ['ROUND2-ROLE', 'round2-role-uid'],
        ['ROUND2-SUSPENDED', 'round2-suspended-uid'],
        ['ROUND2-CAP', 'round2-cap-uid'],
      ]) {
        const card = session.page.locator(
          `[flt-semantics-identifier="account-repair-missingAccess-${recordId}-${uid}"]`,
        );
        await B.scrollIntoView(session.page, card, { bottomInset: 0 });
        assert.equal(await card.count(), 1, `${recordId}: expected a blocked finding`);
        assert.equal(await card.getByRole('button', { name: 'Confirm repair', exact: true }).count(), 0,
          `${recordId}: unsafe repair must not be offered`);
        assert.equal(await db.get('user_access', uid), null,
          `${recordId}: scan must not create an access record`);
      }
      const salesmanCard = session.page.locator(
        '[flt-semantics-identifier="account-repair-invalidSalesmanSupervisor-ROUND2-SALE-round2-supervisor-uid"]',
      );
      await B.scrollIntoView(session.page, salesmanCard, { bottomInset: 0 });
      assert.equal(await salesmanCard.getByRole('button', { name: 'Confirm repair', exact: true }).count(), 0,
        'a real supervisor needing access repair must not lose its assignment');
      for (const collection of ['users', 'user_access']) {
        const data = await db.get(collection, collection === 'users' ? 'ROUND2-SALE' : 'round2-salesman-uid');
        assert.equal(data.supervisorId, 'ROUND2-SUP');
        assert.equal(data.supervisor_id, 'ROUND2-SUP');
        assert.equal(data.supervisorUid, 'round2-supervisor-uid');
      }
      assert.deepEqual((await db.get('users', 'ROUND2-SUP')).assignedSalesmanCodes, ['ROUND2-SALE']);
      evidence.checks.push('conflicting legacy identity, suspended identity and over-cap supervisor repairs blocked');
      evidence.checks.push('real supervisor awaiting account repair preserves salesman code and UID mirrors');
      await t.shot(session, 'round2-repair-blocked');
      for (const [id] of fixtures) {
        const response = await fetch(`${db.firestoreBase}/users/${id}`, {
          method: 'DELETE', headers: { Authorization: 'Bearer owner' },
        });
        assert(response.ok, `local repair fixture delete: ${response.status}`);
      }
      const response = await fetch(`${db.firestoreBase}/user_access/round2-salesman-uid`, {
        method: 'DELETE', headers: { Authorization: 'Bearer owner' },
      });
      assert(response.ok, `local access fixture delete: ${response.status}`);
    });

    await t.step('empty branch fixture shows an incomplete setup step', async () => {
      const response = await fetch(`${db.firestoreBase}/branches/B1`, {
        method: 'DELETE', headers: { Authorization: 'Bearer owner' },
      });
      assert(response.ok, `local branch fixture delete: ${response.status}`);
      assert.equal(await db.get('branches', 'B1'), null, 'B1 was not removed');
      await db.put('demand_forecasts', 'e2e_setup_stale_forecast', {
        productId: 'e2e_setup_product',
        productName: 'E2E stale forecast fixture',
        reason: 'Stale forecast UI fixture',
        generatedAt: new Date('2020-01-01T00:00:00.000Z'),
      });
      await admin.goToPage(session.page, 'Dashboard');
      await B.see(session.page, 'Get set up');
      await B.see(session.page, /Create a branch[^]*Not done/);
      evidence.checks.push('branch step incomplete before creation');
      await t.shot(session, 'setup-before');
      const wideTitle = await B.semantic(session.page, 'Get set up').boundingBox();
      await session.page.setViewportSize({ width: 390, height: 844 });
      await session.page.waitForTimeout(500);
      const narrowTitle = await B.semantic(session.page, 'Get set up').boundingBox();
      const dismiss = await session.page.getByRole('button', { name: 'Dismiss setup checklist' }).boundingBox();
      assert.ok(narrowTitle.width >= wideTitle.width - 1, `checklist title squeezed: ${narrowTitle.width} < ${wideTitle.width}`);
      assert.ok(dismiss.x + dismiss.width <= 390, 'checklist header must fit at 390px');
      await B.semantic(session.page, /^Show \d+ done$/).click();
      await session.page.waitForTimeout(400);
      await t.shot(session, 'setup-show-all-390');
      await session.page.setViewportSize({ width: 1600, height: 1000 });
      await session.page.waitForTimeout(500);
      evidence.checks.push('checklist header fits at 390px without squeezing its title');
    });

    await t.step('creating a branch ticks the live checklist on returning home', async () => {
      await admin.createBranch(session.page, 'E2E Setup Branch');
      const branch = await db.waitForDoc('branches', 'e2e_setup_branch', (data) => data.branchName === 'E2E Setup Branch');
      assert.equal(branch.status, 'active');
      assert.equal(branch.branchName, 'E2E Setup Branch');
      await session.page.mouse.move(120, 400);
      await session.page.mouse.wheel(0, -1600);
      await admin.goToPage(session.page, 'Dashboard');
      await B.scrollIntoView(session.page, B.semantic(session.page, 'Get set up'),
        { step: -300, pointerY: 0.9, bottomInset: 0 });
      await showDoneSteps(session.page);
      await B.see(session.page, /Create a branch[^]*Done/);
      evidence.checks.push('branch step complete after dashboard creation');
      await t.shot(session, 'setup-after');
      const setTheme = async (theme) => {
        await session.page.getByRole('button', { name: /E2E Admin/ }).first().click();
        await B.semantic(session.page, /^Appearance/).click();
        await B.semantic(session.page, new RegExp(`^${theme}$`)).click();
        await session.page.waitForTimeout(700);
        await session.page.keyboard.press('Escape');
        await session.page.waitForTimeout(600);
      };
      await setTheme('Dark');
      await t.shot(session, 'overview-dark');
      await setTheme('Light');
    });

    await t.step('dismissal survives a browser reload', async () => {
      await session.page.getByRole('button', { name: 'Dismiss setup checklist' }).click();
      await B.semantic(session.page, 'Get set up').waitFor({ state: 'detached' });
      await session.page.reload();
      await B.enableSemantics(session.page);
      await admin.waitForShell(session.page);
      assert.equal(await B.semantic(session.page, 'Get set up').count(), 0);
      evidence.checks.push('browser dismissal persisted');
      await t.shot(session, 'setup-dismissed');
    });

    await t.step('the admin can restore a dismissed setup checklist', async () => {
      await session.page.getByRole('button', { name: 'Show setup checklist', exact: true }).click();
      await B.see(session.page, 'Get set up');
      await showDoneSteps(session.page);
      await B.see(session.page, /Create a branch[^]*Done/);
      await session.page.reload();
      await B.enableSemantics(session.page);
      await admin.waitForShell(session.page);
      await B.see(session.page, 'Get set up');
      evidence.checks.push('admin can restore the dismissed per-user checklist and restoration survives reload');
      await t.shot(session, 'setup-restored');
    });

    await predictionRegression(t, session);

    fs.writeFileSync(path.join(E.OUTPUT_DIR, 'dashboard_setup', 'result.json'),
      JSON.stringify({ ...evidence, passed: true }, null, 2));
  },
};
