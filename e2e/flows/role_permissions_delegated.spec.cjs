'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const { putPerson, RETAILERS, PRODUCTS } = require('../lib/seed.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'role_permissions_delegated');
const JAYSON = { email: 'e2e.jayson@example.test', name: 'E2E Jayson', role: 'salesman', code: 'S002' };
const OTHER_SHOP = { id: 'ret-3', name: 'Other Team Mart' };
const SAVE_SHEET = { name: 'Save sheet', exact: true };
const MODULES = ['Products', 'Departments', 'Categories', 'Retailer Score Sheets', 'Retailer Department PIC', 'Website Content'];
const NEW_PRICE = 31.4;
const DELETE_ME = { id: 'prod-delete-me', name: 'E2E PRODUCT TO DELETE' };
const PRODUCTS_BUTTON = /^Products(, .*)?$/;

function expectEqual(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

async function directWrite(db, idToken, collection, docId, fields) {
  const mask = Object.keys(fields).map((key) => `updateMask.fieldPaths=${encodeURIComponent(key)}`).join('&');
  const res = await fetch(`${db.firestoreBase}/${collection}/${encodeURIComponent(docId)}?${mask}`, {
    method: 'PATCH',
    headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${idToken}`, Connection: 'close' },
    body: JSON.stringify({ fields: E.toFields(fields) }),
  });
  return res.status;
}

module.exports = {
  name: 'role_permissions_delegated',
  async run(t) {
    const { db, accounts, seed } = t;
    const evidence = { project: E.PROJECT, checks: [], timingsMs: {} };
    const note = (check, detail = {}) => evidence.checks.push({ check, ...detail });
    let adminS;
    let supS;
    let supToken;
    let marker;

    const matrix = () => db.get('system_access_config', 'permission_matrix');
    const mirror = () => db.get('role_permission_grants', 'supervisor');
    const saveSheet = () => supS.page.getByRole('button', SAVE_SHEET);
    const tick = (label) => adminS.page.getByRole('checkbox', { name: label, exact: true });
    const saveGrants = async () => {
      await adminS.page.getByRole('button', { name: 'Save changes', exact: true }).click();
      const clickedAt = Date.now();
      await B.see(adminS.page, 'Permissions saved and recorded in the audit log.');
      return clickedAt;
    };
    const pickSupervisorRole = async () => {
      await adminS.page.getByRole('button', { name: 'Supervisor', exact: true }).first().click();
    };
    const supervisorStillSamePage = async () => {
      expectEqual(await supS.page.evaluate(() => window.__e2eMarker), marker, 'supervisor page was not reloaded');
    };
    const openMenuLabels = async (buttonName) => {
      await supS.page.getByRole('button', { name: buttonName }).first().click();
      await supS.page.getByRole('menuitem').first().waitFor({ timeout: 15000 });
      await supS.page.waitForFunction(() => Array.from(document.querySelectorAll('flt-semantics[role="menuitem"]'))
        .every((n) => (n.getAttribute('aria-label') || n.textContent || '').trim()), null, { timeout: 5000 });
      const labels = await supS.page.getByRole('menuitem').evaluateAll((nodes) => nodes.map((n) => (n.getAttribute('aria-label') || n.textContent || '').trim()));
      await supS.page.keyboard.press('Escape');
      await supS.page.waitForTimeout(300);
      return labels.filter(Boolean);
    };
    const retailerChoices = async () => (await openMenuLabels('Choose retailer')).sort();

    await t.step('seed a second team: Jayson S002 with an own shop, outside the supervisor team', async () => {
      await putPerson(db, JAYSON, { supervisorCode: 'SUP-OTHER' });
      await db.put('products', DELETE_ME.id, {
        ...(await db.get('products', PRODUCTS[2].id)), productId: DELETE_ME.id, productName: DELETE_ME.name, itemName: DELETE_ME.name,
        barcode: '9555000000999', itemBarcode: '9555000000999', itemCode: 'DEL-1', productCode: 'DEL-1', sku: 'DEL-1', isVisible: false, status: 'hidden',
      });
      await db.put('retailers', OTHER_SHOP.id, {
        retailerId: OTHER_SHOP.id, retailerName: OTHER_SHOP.name, name: OTHER_SHOP.name, area: 'Satok',
        branchId: seed.branch.id, status: 'active', address: 'Satok, Kuching',
        latitude: 1.55, longitude: 110.35, coordinateStatus: 'verified', coordinateReviewStatus: 'reviewed',
        assignedSalesmanId: JAYSON.code,
      });
      await db.put('retailer_score_sheet_settings', OTHER_SHOP.id, {
        retailerId: OTHER_SHOP.id, retailerName: OTHER_SHOP.name,
        visibleProductIds: PRODUCTS.map((p) => p.id), hiddenProductIds: [], disabledProductIds: [],
        sheetName: `${OTHER_SHOP.name} Score Sheet`,
      });
      expectEqual(await matrix(), null, 'no stored table at the start');
    });

    await t.step('the supervisor picks a salesperson and sees only that team shops, view only', async () => {
      supS = await t.session('admin', { name: 'supervisor', viewport: { width: 1600, height: 1200 } });
      await B.loginAdmin(supS.page, supS.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(supS.page);
      await admin.goToPage(supS.page, 'Score Sheets');
      await B.see(supS.page, 'Retailer Score Sheets');
      const people = await openMenuLabels('Choose salesperson');
      expectEqual(people.filter((p) => p !== 'Choose salesperson'), ['E2E Salesperson'], 'salespeople offered to the supervisor');
      await admin.pickDropdown(supS.page, 'Choose salesperson', 'E2E Salesperson');
      expectEqual(await retailerChoices(), RETAILERS.map((r) => r.name).sort(), 'shops of E2E Salesperson');
      await admin.pickDropdown(supS.page, 'Choose retailer', RETAILERS[0].name);
      await B.see(supS.page, 'View only');
      expectEqual(await saveSheet().count(), 0, 'Save sheet buttons before any tick');
      marker = await supS.page.evaluate(() => { window.__e2eMarker = Math.random().toString(36).slice(2); return window.__e2eMarker; });
      await t.shot(supS, 'supervisor-view-only');
      note('supervisor sees own salesperson shops and no Save sheet', { shops: RETAILERS.map((r) => r.name) });
    });

    await t.step('a direct write by the supervisor is refused before any tick', async () => {
      supToken = (await db.ensureUser(accounts.supervisor.email, accounts.supervisor.name)).idToken;
      expectEqual(await directWrite(db, supToken, 'retailer_score_sheet_settings', RETAILERS[0].id, { sheetName: 'forged' }), 403, 'own shop before the tick');
      const stored = await db.get('retailer_score_sheet_settings', RETAILERS[0].id);
      expectEqual(stored.sheetName, `${RETAILERS[0].name} Score Sheet`, 'sheet name unchanged');
      note('direct write before tick refused', { status: 403 });
    });

    await t.step('admin opens Role Permissions: every write box can be ticked for Supervisor', async () => {
      adminS = await t.session('admin', { name: 'admin', viewport: { width: 1600, height: 1700 } });
      await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
      await admin.waitForShell(adminS.page);
      await admin.goToPage(adminS.page, 'Role Permissions');
      await B.see(adminS.page, 'No stored table yet');
      await pickSupervisorRole();
      await B.see(adminS.page, 'Create, Edit and Delete apply to the whole company. Edit includes prices.');
      await B.see(adminS.page, 'Create, Edit and Delete apply to shops of their own team only, never the company default sheet. Edit includes prices.');
      for (const module of MODULES) {
        for (const action of ['Create', 'Edit', 'Delete']) {
          expectEqual(await tick(`${module} ${action}`).isDisabled(), false, `${module} ${action} enabled for Supervisor`);
          expectEqual(await tick(`${module} ${action}`).isChecked(), false, `${module} ${action} unticked at the start`);
        }
      }
      const settles = async (label, disabled) => {
        for (let i = 0; i < 40 && (await tick(label).isDisabled()) !== disabled; i += 1) await adminS.page.waitForTimeout(250);
        return tick(label).isDisabled();
      };
      await tick('Departments View').click();
      expectEqual(await settles('Departments Edit', true), true, 'Departments Edit needs View');
      await tick('Departments View').click();
      expectEqual(await settles('Departments Edit', false), false, 'Departments Edit back with View');
      await t.shot(adminS, 'admin-matrix-supervisor');
      note('every module is tickable for Supervisor; a write needs View');
    });

    await t.step('admin ticks Score Sheets Edit, PIC Create and Products Edit; the supervisor page changes without a reload', async () => {
      expectEqual(await supS.page.getByRole('button', { name: PRODUCTS_BUTTON }).count(), 0, 'no Products page before the tick');
      for (const label of ['Retailer Score Sheets Edit', 'Retailer Department PIC Create', 'Products Edit', 'Products Delete']) {
        await tick(label).click();
        for (let i = 0; i < 40 && !(await tick(label).isChecked()); i += 1) await adminS.page.waitForTimeout(250);
        expectEqual(await tick(label).isChecked(), true, `${label} shows ticked after the click`);
      }
      await t.shot(adminS, 'admin-ticked-before-save');
      const clickedAt = await saveGrants();
      await saveSheet().waitFor({ state: 'attached', timeout: 15000 });
      evidence.timingsMs.tickToSaveSheetVisible = Date.now() - clickedAt;
      await supervisorStillSamePage();
      const stored = await matrix();
      expectEqual(stored.roles.supervisor.includes('retailer_scoresheets:edit'), true, 'matrix has the Edit tick');
      expectEqual(stored.roles.supervisor.includes('department_pic:create'), true, 'matrix has the PIC Create tick');
      expectEqual(stored.roles.supervisor.includes('products:edit'), true, 'matrix has the Products Edit tick');
      const copy = await mirror();
      expectEqual(copy.shape, 3, 'readable copy shape');
      expectEqual([...copy.grants].sort(), [...stored.roles.supervisor].sort(), 'readable copy equals the stored row');
      await t.shot(supS, 'supervisor-after-tick');
      note('tick reached the open supervisor page', { ms: evidence.timingsMs.tickToSaveSheetVisible, revision: stored.revision });
    });

    await t.step('the supervisor edits an own-team shop sheet; the company default sheet is untouched', async () => {
      const defaultBefore = await db.get('score_sheets', 'default');
      await supS.page.getByRole('button', { name: 'Hide selected', exact: true }).click();
      await saveSheet().click();
      await B.see(supS.page, 'Retailer score sheet settings saved.');
      const stored = await db.waitForDoc('retailer_score_sheet_settings', RETAILERS[0].id, (d) => (d.hiddenProductIds || []).length === PRODUCTS.length, { label: 'sheet saved by the supervisor' });
      expectEqual((stored.hiddenProductIds || []).length, PRODUCTS.length, 'every product hidden on mobile by the supervisor');
      expectEqual(await db.get('score_sheets', 'default'), defaultBefore, 'company default sheet unchanged');
      await supervisorStillSamePage();
      await t.shot(supS, 'supervisor-saved');
      note('supervisor saved own-team sheet', { hiddenProductIds: stored.hiddenProductIds });
    });

    await t.step('direct writes: own shop allowed, another team shop, default sheet, products, other module refused', async () => {
      expectEqual(await directWrite(db, supToken, 'retailer_score_sheet_settings', RETAILERS[0].id, { sheetName: 'renamed by supervisor' }), 200, 'own shop with the tick');
      expectEqual(await directWrite(db, supToken, 'retailer_score_sheet_settings', OTHER_SHOP.id, { sheetName: 'forged' }), 403, 'another team shop');
      expectEqual(await directWrite(db, supToken, 'score_sheets', 'default', { sheetName: 'forged' }), 403, 'company default sheet');
      expectEqual(await directWrite(db, supToken, 'products', PRODUCTS[1].id, { sortOrder: 7 }), 200, 'products with the Edit tick');
      expectEqual(await directWrite(db, supToken, 'products', PRODUCTS[1].id, { unitPrice: 1 }), 403, 'a price change without the server time stamp, even with the Edit tick');
      expectEqual(await directWrite(db, supToken, 'products', PRODUCTS[1].id, { isVisible: true, status: 'active' }), 403, 'product visibility is not a direct write');
      expectEqual(await directWrite(db, supToken, 'departments', 'dept-x', { name: 'forged' }), 403, 'departments without a tick');
      expectEqual((await db.get('retailer_score_sheet_settings', OTHER_SHOP.id)).sheetName, `${OTHER_SHOP.name} Score Sheet`, 'other team sheet unchanged');
      note('direct writes', { ownShop: 200, otherTeamShop: 403, defaultSheet: 403, productsTicked: 200, departments: 403 });
    });

    await t.step('the supervisor opens Products from the rail and changes a price on screen', async () => {
      await admin.goToPage(supS.page, 'Products');
      const name = PRODUCTS[0].name.replace(/[()]/g, '\\$&');
      const row = supS.page.getByRole('button', { name: new RegExp(`^Product ${name}`) }).first();
      await row.waitFor({ timeout: 20000 });
      await row.hover();
      await supS.page.getByRole('button', { name: new RegExp(`^Edit ${name}`) }).click();
      await B.fillField(supS.page, supS.page.getByRole('textbox', { name: /^Unit Price\b/ }).first(), String(NEW_PRICE));
      await supS.page.getByRole('button', { name: 'Save', exact: true }).click();
      await B.see(supS.page, 'Product item saved.');
      const stored = await db.waitForDoc('products', PRODUCTS[0].id, (p) => Math.abs((p.unitPrice || 0) - NEW_PRICE) < 0.001, { label: 'price saved by the supervisor' });
      await B.see(supS.page, new RegExp(`RM ${NEW_PRICE.toFixed(2)}`));
      await supervisorStillSamePage();
      await t.shot(supS, 'supervisor-product-price');
      const doomed = supS.page.getByRole('button', { name: new RegExp(`^Product ${DELETE_ME.name}`) }).first();
      await doomed.hover();
      await supS.page.getByRole('button', { name: new RegExp(`^Delete ${DELETE_ME.name}`) }).click();
      await supS.page.getByRole('button', { name: 'Delete', exact: true }).last().click();
      await B.see(supS.page, `Deleted ${DELETE_ME.name}.`);
      for (let i = 0; i < 40 && (await db.get('products', DELETE_ME.id)); i += 1) await supS.page.waitForTimeout(250);
      expectEqual(await db.get('products', DELETE_ME.id), null, 'product deleted by the supervisor through the server');
      await doomed.waitFor({ state: 'detached', timeout: 15000 });
      await t.shot(supS, 'supervisor-product-deleted');
      note('supervisor changed a product price through the Products page', { unitPrice: stored.unitPrice });
    });

    await t.step('the supervisor sees the PIC page enabled while ticked', async () => {
      await admin.goToPage(supS.page, 'Department PIC');
      await B.see(supS.page, 'Department PIC assignments');
      expectEqual(await supS.page.getByRole('button', { name: 'Add PIC' }).first().isDisabled(), false, 'Add PIC disabled while ticked');
      await t.shot(supS, 'supervisor-pic-enabled');
      await admin.goToPage(supS.page, 'Score Sheets');
      await B.see(supS.page, 'Retailer Score Sheets');
    });

    await t.step('admin unticks; the supervisor Save sheet disappears without a reload and the write is refused', async () => {
      await admin.goToPage(supS.page, 'Score Sheets');
      await B.see(supS.page, 'Retailer Score Sheets');
      for (const label of ['Retailer Score Sheets Edit', 'Retailer Department PIC Create', 'Products Edit', 'Products Delete']) {
        await tick(label).click();
        for (let i = 0; i < 40 && (await tick(label).isChecked()); i += 1) await adminS.page.waitForTimeout(250);
        expectEqual(await tick(label).isChecked(), false, `${label} shows unticked after the click`);
      }
      const clickedAt = await saveGrants();
      await saveSheet().waitFor({ state: 'detached', timeout: 15000 });
      evidence.timingsMs.untickToSaveSheetGone = Date.now() - clickedAt;
      await supervisorStillSamePage();
      expectEqual(await directWrite(db, supToken, 'retailer_score_sheet_settings', RETAILERS[0].id, { sheetName: 'after untick' }), 403, 'own shop after the untick');
      expectEqual((await db.get('retailer_score_sheet_settings', RETAILERS[0].id)).sheetName, 'renamed by supervisor', 'sheet unchanged after the untick');
      expectEqual((await mirror()).grants.every((token) => token.endsWith(':view')), true, 'readable copy keeps only the view entries');
      expectEqual(await supS.page.getByRole('button', { name: PRODUCTS_BUTTON }).count(), 0, 'Products page gone from the supervisor rail');
      expectEqual(await directWrite(db, supToken, 'products', PRODUCTS[1].id, { sortOrder: 8 }), 403, 'products after the untick');
      await t.shot(supS, 'supervisor-after-untick');
      note('untick reached the open supervisor page', { ms: evidence.timingsMs.untickToSaveSheetGone });
    });

    await t.step('the PIC Add button is disabled again and the change is audited', async () => {
      await admin.goToPage(supS.page, 'Department PIC');
      await B.see(supS.page, 'Department PIC assignments');
      expectEqual(await supS.page.getByRole('button', { name: 'Add PIC' }).first().isDisabled(), true, 'Add PIC disabled after the untick');
      const audits = (await db.list('system_audit_logs')).filter((a) => a.action === 'permission_matrix_updated');
      expectEqual(audits.length, 2, 'permission audit entries');
      note('PIC disabled after untick', { audits: audits.length });
    });

    fs.mkdirSync(OUT, { recursive: true });
    fs.writeFileSync(path.join(OUT, 'result.json'), `${JSON.stringify(evidence, null, 2)}\n`);
  },
};
