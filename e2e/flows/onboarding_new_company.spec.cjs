'use strict';

const crypto = require('node:crypto');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const ui = require('../lib/onboarding_ui.cjs');

const NEW_PROJECT = `demo-onbnewui-${crypto.randomBytes(3).toString('hex')}`;
const LEGAL_NAME = 'Onboard New UI Sdn Bhd';
const ADMIN = { name: 'Nina New', email: 'nina.new.ui@example.test', code: 'ADM001' };

module.exports = {
  name: 'onboarding_new_company',
  platformApi: false,
  async run(t) {
    const walk = await ui.startWalk(t, { outName: 'onboarding_new_company', project: NEW_PROJECT });
    const { button, dialogButton, text, api } = walk;
    let draftId;
    let tenant;
    let operator;
    let engineer;
    let owner;
    const green = (...steps) => steps;

    try {
      await t.step('operator, engineer and owner sign in to the Control Centre', async () => {
        operator = await walk.open('operator');
        owner = await walk.open('owner');
        await E.client(NEW_PROJECT).reset();
      });

      await t.step('1. operator adds the company and the checklist opens with the details step green', async () => {
        await ui.createDraftOnPage(walk, operator, {
          'Company name': LEGAL_NAME,
          'Workspace code': 'ONBNEWUI',
          'First administrator name': ADMIN.name,
          'First administrator email': ADMIN.email,
          'First administrator employee code': ADMIN.code,
          'Billing email': 'billing@onbnewui.example',
        }, 'Standard');
        await t.shot(operator, 'draft-created');
        await button(operator, 'Open checklist').click();
        const listed = (await api('owner', 'GET', '/onboarding-drafts')).drafts.find((d) => d.legalName === LEGAL_NAME);
        draftId = listed.draftId;
        const v = await walk.record(draftId, 'draft created', 'Add company, Create draft', green(1), 'Connect project');
        await walk.expectPage(operator, v);
        await text(operator, 'Waiting for the owner: Connect project.').waitFor({ timeout: 15000 });
        await walk.shoot(operator, '01-draft-created');
      });

      await t.step('2. engineer connects a new empty project and the project step turns green', async () => {
        engineer = await walk.open('engineer');
        await walk.openChecklist(engineer, LEGAL_NAME);
        await button(engineer, 'Connect project').click();
        await B.fillField(engineer.page, engineer.page.getByRole('textbox', { name: 'Firebase project ID', exact: true }), NEW_PROJECT);
        await walk.shoot(engineer, '02a-connect-dialog');
        await dialogButton(engineer, 'Connect').click();
        await dialogButton(engineer, 'Close').waitFor({ timeout: 60000 });
        await walk.shoot(engineer, '02b-connect-result');
        await dialogButton(engineer, 'Close').click();
        const v = await walk.record(draftId, 'after Connect project', 'Connect project (engineer)', green(1, 2), 'Prepare company data');
        ui.expectEqual(v.kind, 'new', 'an empty project is New');
        tenant = v.tenantId;
        await walk.expectPage(engineer, v);
        await text(engineer, 'Kind: New').waitFor({ timeout: 15000 });
        await walk.shoot(engineer, '02-project-connected');
      });

      await t.step('3. owner prepares the company data and the people step turns green', async () => {
        await walk.openChecklist(owner, LEGAL_NAME);
        await button(owner, 'Prepare company data').click();
        await walk.shoot(owner, '03a-prepare-dialog');
        await dialogButton(owner, 'Prepare company data').click();
        await text(owner, 'Company data is prepared.').first().waitFor({ timeout: 60000 });
        const v = await walk.record(draftId, 'after Prepare company data', 'Prepare company data (owner)', green(1, 2, 3), 'Apply package');
        await walk.expectPage(owner, v);
        await walk.shoot(owner, '03-people-green');
      });

      await ui.packageAndPayment(t, walk, { owner, operator, draftId, tenant, legalName: LEGAL_NAME, tag: 'onbnewui', moneyBase: [1, 2, 3] });

      await t.step('6. owner gives access, the invitation waits, the person accepts, the admin step turns green', async () => {
        await button(owner, 'Give access').click();
        await walk.shoot(owner, '06a-give-access-dialog');
        await dialogButton(owner, 'Give access').click();
        await text(owner, /^An invitation was sent to /).first().waitFor({ timeout: 40000 });
        let v = await walk.record(draftId, 'after Give access (invitation sent)', 'Give access (owner)', green(1, 2, 3, 4, 5), 'Resend invitation');
        await walk.expectPage(owner, v);
        await walk.shoot(owner, '06-invitation-sent');
        await button(owner, 'Resend invitation').click();
        await text(owner, 'The invitation was sent again.').first().waitFor({ timeout: 40000 });
        v = await walk.record(draftId, 'after Resend invitation', 'Resend invitation (owner)', green(1, 2, 3, 4, 5), 'Resend invitation');
        await walk.shoot(owner, '06b-invitation-resent');
        const accepted = await ui.acceptFirstAdminInvitation(E.client(NEW_PROJECT), NEW_PROJECT, ADMIN.email);
        ui.expectTrue(accepted, 'the invited access row was found and accepted');
        await walk.openChecklist(owner, LEGAL_NAME);
        v = await walk.record(draftId, 'after the person accepts', 'the invited person accepts (setup, not a screen)', green(1, 2, 3, 4, 5, 6, 7), 'Make active');
        await walk.expectPage(owner, v);
        await walk.shoot(owner, '06c-admin-and-rules-green');
      });

      await t.step('8. owner presses Make active and all eight steps are green', async () => {
        await button(owner, 'Make active').click();
        await B.fillField(owner.page, owner.page.getByRole('textbox', { name: 'Reason', exact: true }), 'All steps are green');
        await walk.shoot(owner, '08a-make-active-dialog');
        await dialogButton(owner, 'Make active').click();
        await text(owner, 'The company is active.').first().waitFor({ timeout: 60000 });
        const v = await walk.record(draftId, 'after Make active', 'Make active (owner)', green(1, 2, 3, 4, 5, 6, 7, 8), null);
        ui.expectEqual([v.phase, v.lifecycleState], ['working', 'active'], 'the company is working and active');
        await walk.expectPage(owner, v);
        await walk.shoot(owner, '08-all-green');
        await button(owner, 'Back to onboarding').click();
        await button(owner, /^Working/).click();
        await button(owner, `Open checklist for ${LEGAL_NAME}`).waitFor({ timeout: 25000 });
        await walk.shoot(owner, '08b-working-tab');
        const company = await walk.platformDb.get('companies', tenant);
        ui.expectEqual(company.status, 'live', 'company record status');
      });
    } finally {
      await walk.stop();
    }
  },
};
