'use strict';

const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const ui = require('../lib/onboarding_ui.cjs');
const { seedLegacyCompany } = require('../lib/legacy_company_fixture.cjs');

const LEGAL_NAME = 'Onboard Existing UI Sdn Bhd';

module.exports = {
  name: 'onboarding_byo_company',
  platformApi: false,
  async run(t) {
    const walk = await ui.startWalk(t, { outName: 'onboarding_byo_company', project: E.PROJECT });
    const { button, dialogButton, text, api } = walk;
    let draftId;
    let tenant;
    let operator;
    let engineer;
    let owner;
    let seeded;

    try {
      await t.step('an existing project with people and one swapped row is seeded; operator, engineer and owner sign in', async () => {
        const projectDb = E.client(E.PROJECT);
        const projectAuth = { authBase: projectDb.authBase, project: E.PROJECT };
        seeded = await seedLegacyCompany(projectDb, projectAuth, { shapes: ['swappedRow'] });
        operator = await walk.open('operator');
        owner = await walk.open('owner');
      });

      await t.step('1. operator adds the company with the existing administrator', async () => {
        const admin = seeded.people.admin;
        await ui.createDraftOnPage(walk, operator, {
          'Company name': LEGAL_NAME,
          'Workspace code': 'ONBOLDUI',
          'First administrator name': admin.name,
          'First administrator email': admin.email,
          'First administrator employee code': admin.code,
          'Billing email': 'billing@onboldui.example',
        }, 'Standard');
        await t.shot(operator, 'draft-created');
        await button(operator, 'Open checklist').click();
        draftId = (await api('owner', 'GET', '/onboarding-drafts')).drafts.find((d) => d.legalName === LEGAL_NAME).draftId;
        const v = await walk.record(draftId, 'draft created', 'Add company, Create draft', [1], 'Connect project');
        await walk.expectPage(operator, v);
        await walk.shoot(operator, '01-draft-created');
      });

      await t.step('2. engineer connects the existing project; it is read as an Existing project and the people step is red', async () => {
        engineer = await walk.open('engineer');
        await walk.openChecklist(engineer, LEGAL_NAME);
        await button(engineer, 'Connect project').click();
        await B.fillField(engineer.page, engineer.page.getByRole('textbox', { name: 'Firebase project ID', exact: true }), E.PROJECT);
        await dialogButton(engineer, 'Connect').click();
        await dialogButton(engineer, 'Close').waitFor({ timeout: 60000 });
        await text(engineer, /Existing project/).first().waitFor({ timeout: 15000 });
        await walk.shoot(engineer, '02a-connect-result-existing');
        await dialogButton(engineer, 'Close').click();
        const v = await walk.record(draftId, 'after Connect project', 'Connect project (engineer)', [1, 2], 'Prepare company data');
        ui.expectEqual(v.kind, 'existing', 'a project with people is Existing');
        ui.expectEqual(v.steps[2].state, 'red', 'people step is red for the swapped row');
        tenant = v.tenantId;
        await walk.expectPage(engineer, v);
        await text(engineer, 'Kind: Existing').waitFor({ timeout: 15000 });
        await walk.shoot(engineer, '02-existing-people-red');
      });

      await t.step('2b. after Connect, the operator header Edit details is admin-only: the company name is read-only and the employee code saves', async () => {
        const original = seeded.people.admin.code;
        const codeField = (s) => s.page.getByRole('textbox', { name: 'First administrator employee code', exact: true });
        await walk.openChecklist(operator, LEGAL_NAME);
        await button(operator, 'Edit details').click();
        const nameField = operator.page.getByRole('textbox', { name: 'Company name', exact: true });
        await nameField.waitFor({ timeout: 15000 });
        await nameField.click();
        await operator.page.keyboard.type('ZZ');
        ui.expectEqual(await nameField.inputValue(), LEGAL_NAME, 'Company name is locked after Connect: typing does not change it');
        await text(operator, 'Locked after the project is connected.').first().waitFor({ timeout: 5000 });
        await B.fillField(operator.page, codeField(operator), `${original}-X`);
        await walk.shoot(operator, '02b-edit-details-admin-only');
        await dialogButton(operator, 'Save changes').click();
        await text(operator, 'The details were saved.').first().waitFor({ timeout: 30000 });
        let v = await walk.record(draftId, 'after Edit details (employee code changed)', 'Edit details, Save changes', [1, 2], 'Prepare company data');
        ui.expectEqual(v.adminEmployeeCode, `${original}-X`, 'the new employee code is stored');
        await walk.expectPage(operator, v);
        await button(operator, 'Edit details').click();
        await B.fillField(operator.page, codeField(operator), original);
        await dialogButton(operator, 'Save changes').click();
        await text(operator, 'The details were saved.').first().waitFor({ timeout: 30000 });
        v = await walk.record(draftId, 'after Edit details (employee code restored)', 'Edit details, Save changes', [1, 2], 'Prepare company data');
        ui.expectEqual(v.adminEmployeeCode, original, 'the employee code is back to the seeded one');
      });

      await t.step('3. owner prepares the company data and the people step turns green', async () => {
        await walk.openChecklist(owner, LEGAL_NAME);
        await button(owner, 'Prepare company data').click();
        await walk.shoot(owner, '03a-prepare-dialog');
        await dialogButton(owner, 'Prepare company data').click();
        await text(owner, 'Company data is prepared.').first().waitFor({ timeout: 60000 });
        const v = await walk.record(draftId, 'after Prepare company data', 'Prepare company data (owner)', [1, 2, 3], 'Apply package');
        await walk.expectPage(owner, v);
        await walk.shoot(owner, '03-people-green');
      });

      await ui.packageAndPayment(t, walk, { owner, operator, draftId, tenant, legalName: LEGAL_NAME, tag: 'onbolddui', moneyBase: [1, 2, 3],
        afterPayment: { green: [1, 2, 3, 4, 5, 6, 7], next: 'Make active' } });

      await t.step('6. the existing administrator is already active under the same uid, so the admin and rules steps are green without Give access', async () => {
        const v = await walk.record(draftId, 'existing administrator', 'none (read only)', [1, 2, 3, 4, 5, 6, 7], 'Make active');
        const row = (await E.client(E.PROJECT).list('user_access')).find((r) => r.id === seeded.uids.admin);
        ui.expectTrue(row && row.status === 'active', 'the old admin access row is active under the same uid');
        ui.expectEqual(await owner.page.getByRole('button', { name: 'Give access', exact: true }).count(), 0, 'Give access is not offered for an active administrator');
        await walk.expectPage(owner, v);
        await walk.shoot(owner, '06-admin-and-rules-green');
      });

      await t.step('8. owner presses Make active and all eight steps are green', async () => {
        await button(owner, 'Make active').click();
        await B.fillField(owner.page, owner.page.getByRole('textbox', { name: 'Reason', exact: true }), 'All steps are green');
        await dialogButton(owner, 'Make active').click();
        await text(owner, 'The company is active.').first().waitFor({ timeout: 60000 });
        const v = await walk.record(draftId, 'after Make active', 'Make active (owner)', [1, 2, 3, 4, 5, 6, 7, 8], null);
        ui.expectEqual([v.phase, v.lifecycleState], ['working', 'active'], 'the company is working and active');
        await walk.expectPage(owner, v);
        await walk.shoot(owner, '08-all-green');
        const company = await walk.platformDb.get('companies', tenant);
        ui.expectEqual(company.status, 'live', 'company record status');
      });
    } finally {
      await walk.stop();
    }
  },
};
