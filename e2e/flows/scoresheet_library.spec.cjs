'use strict';

const assert = require('node:assert/strict');
const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const { ACCOUNTS, PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

module.exports = {
  name: 'scoresheet_library',
  async run(t) {
    const { db } = t;
    const pageSession = await t.session('admin');
    const baseName = `Library ${Date.now()}`;
    const copyName = `${baseName} copy`;
    const secondSalesman = {
      email: `e2e.sales2.${Date.now()}@example.test`,
      name: 'E2E Second Salesperson',
      employeeCode: 'S002',
    };
    const secondIdentity = await db.ensureUser(secondSalesman.email, secondSalesman.name);
    await db.put('users', secondSalesman.email, {
      uid: secondIdentity.uid,
      userUid: secondIdentity.uid,
      name: secondSalesman.name,
      email: secondSalesman.email,
      role: 'salesman',
      user_group: 'salesman',
      status: 'active',
      employeeCode: secondSalesman.employeeCode,
      userId: secondSalesman.employeeCode,
      branchId: t.seed.branch.id,
    });
    await db.put('user_access', secondIdentity.uid, {
      accessVersion: 2,
      uid: secondIdentity.uid,
      email: secondSalesman.email,
      role: 'salesman',
      user_group: 'salesman',
      status: 'active',
      isActive: true,
      branchId: t.seed.branch.id,
    });

    await t.step('admin opens the existing score sheet editor', async () => {
      await B.loginAdmin(pageSession.page, pageSession.url, ACCOUNTS.admin.email);
      await admin.waitForShell(pageSession.page);
      await admin.goToPage(pageSession.page, 'Score Sheets');
      await B.see(pageSession.page, 'Retailer Score Sheets');
    });

    await t.step('admin creates a reusable versioned template from a retailer sheet', async () => {
      const page = pageSession.page;
      await admin.pickDropdown(page, 'Choose retailer', RETAILERS[0].name);
      await page.getByRole('button', { name: 'Save sheet', exact: true }).waitFor();
      await page.getByRole('button', { name: 'Template library', exact: true }).click();
      await page.getByRole('button', { name: 'Save current sheet as template', exact: true }).click();
      await page.getByRole('textbox', { name: 'Template name' }).fill(baseName);
      await page.getByRole('button', { name: 'Create template', exact: true }).click();
      await B.see(page, baseName);
      const templates = (await db.list('score_sheets')).filter((item) => item.kind === 'template');
      const created = templates.find((item) => item.name === baseName);
      assert.ok(created, 'template is stored in the existing score_sheets collection');
      assert.equal(created.revision, 1);
      assert.ok(Array.isArray(created.productIds));
      assert.deepEqual([...created.productIds].sort(), PRODUCTS.map((p) => p.id).sort());
    });

    await t.step('admin copies a template into an independent version-one template', async () => {
      const page = pageSession.page;
      await page.getByRole('button', { name: `Copy ${baseName}`, exact: true }).click();
      await page.getByRole('textbox', { name: 'Template name' }).fill(copyName);
      await page.getByRole('button', { name: 'Create copy', exact: true }).click();
      await B.see(page, copyName);
      const created = (await db.list('score_sheets')).find((item) => item.name === copyName);
      assert.ok(created);
      assert.equal(created.revision, 1);
      assert.notEqual(created.templateId, (await db.list('score_sheets')).find((item) => item.name === baseName).templateId);
    });

    await t.step('one salesperson can receive both templates and a retailer mapping', async () => {
      const page = pageSession.page;
      const priceOverride = { 'prod-2': { unitPrice: 8.5, price: 8.5, isVisible: true } };
      await db.put('retailer_score_sheet_settings', RETAILERS[0].id, {
        retailerId: RETAILERS[0].id, retailerName: RETAILERS[0].name,
        visibleProductIds: ['prod-1'], hiddenProductIds: ['prod-3'], disabledProductIds: ['prod-2'],
        productOverrides: priceOverride, sheetName: `${RETAILERS[0].name} Score Sheet`,
      });
      for (const name of [baseName, copyName]) {
        await page.getByRole('button', { name: `Assign ${name}`, exact: true }).click();
        await admin.chooseOption(page, 'Salesperson', ACCOUNTS.salesman.name);
        await admin.chooseOption(page, 'Retailer', RETAILERS[0].name);
        await page.getByRole('button', { name: 'Save assignment', exact: true }).click();
        await page.getByRole('button', { name: 'Save assignment', exact: true }).waitFor({ state: 'detached' });
      }
      const assignments = (await db.list('score_sheets')).filter((item) => item.kind === 'assignment' && item.salesmanUid === t.seed.uids.salesman);
      assert.equal(assignments.length, 2);
      assert.ok(assignments.every((item) => item.retailerId === RETAILERS[0].id));
      const sheet = await db.get('retailer_score_sheet_settings', RETAILERS[0].id);
      assert.deepEqual([...sheet.visibleProductIds].sort(), PRODUCTS.map((p) => p.id).sort());
      assert.deepEqual(sheet.hiddenProductIds, []);
      assert.deepEqual(sheet.disabledProductIds, []);
      assert.deepEqual(sheet.productOverrides, priceOverride);
      assert.equal(sheet.appliedTemplateName, copyName);
    });

    await t.step('reassignment appends history and leaves prior events unchanged', async () => {
      const page = pageSession.page;
      const before = (await db.list('score_sheets')).find((item) => item.kind === 'assignment' && item.templateName === baseName);
      await page.getByRole('button', { name: `Reassign ${baseName}`, exact: true }).click();
      await admin.chooseOption(page, 'Salesperson', secondSalesman.name);
      await page.getByRole('button', { name: 'Save reassignment', exact: true }).click();
      await page.getByRole('button', { name: 'Save reassignment', exact: true }).waitFor({ state: 'detached' });
      const events = (await db.list('score_sheets')).filter((item) => item.kind === 'assignment' && item.templateName === baseName);
      assert.equal(events.length, 2);
      const [initial, reassigned] = events.sort((a, b) => a.assignmentRevision - b.assignmentRevision);
      assert.equal(initial.salesmanUid, t.seed.uids.salesman);
      assert.equal(reassigned.salesmanUid, secondIdentity.uid);
      assert.equal(reassigned.assignmentId, initial.assignmentId);
      assert.equal(reassigned.assignmentRevision, initial.assignmentRevision + 1);
      assert.equal(initial.salesmanUid, t.seed.uids.salesman);
      assert.deepEqual(initial, before);
      assert.deepEqual(reassigned.productIds, initial.productIds);
      const sheet = await db.get('retailer_score_sheet_settings', RETAILERS[0].id);
      assert.equal(sheet.appliedAssignmentId, initial.assignmentId);
      assert.equal(sheet.appliedAssignmentRevision, 2);
      assert.equal(sheet.appliedSalesmanUid, secondIdentity.uid);
      await B.see(pageSession.page, 'Assignment history');
    });

    await t.step('changing a template adds a new revision and keeps earlier ones', async () => {
      const page = pageSession.page;
      const versionOne = (await db.list('score_sheets')).find((item) => item.kind === 'template' && item.name === baseName);
      await page.getByRole('button', { name: `New version of ${baseName}`, exact: true }).click();
      await page.getByRole('button', { name: 'Save version', exact: true }).click();
      await page.getByRole('button', { name: 'Save version', exact: true }).waitFor({ state: 'detached' });
      const revisions = (await db.list('score_sheets'))
        .filter((item) => item.kind === 'template' && item.templateId === versionOne.templateId)
        .sort((a, b) => a.revision - b.revision);
      assert.equal(revisions.length, 2);
      assert.deepEqual(revisions[0], versionOne);
      assert.equal(revisions[1].revision, 2);
      assert.equal(revisions[1].name, baseName);
      assert.ok(revisions.every((item) => !('unitPrice' in item) && !('price' in item) && !('productOverrides' in item)));
      const events = (await db.list('score_sheets')).filter((item) => item.kind === 'assignment' && item.templateId === versionOne.templateId);
      assert.ok(events.every((item) => item.templateRevision === 1));
      await B.see(page, /Version 2/);
    });

    await t.step('saving a retailer sheet keeps a product added after its last save on', async () => {
      const page = pageSession.page;
      const retailer = RETAILERS[1];
      const added = { id: 'prod-new', name: 'NEW ARRIVAL OAT (24P X 450G)', code: 'R004-ORG-004', barcode: '9555592202999' };
      await db.put('retailer_score_sheet_settings', retailer.id, {
        retailerId: retailer.id, retailerName: retailer.name, sheetName: `${retailer.name} Score Sheet`,
        visibleProductIds: ['prod-1'], hiddenProductIds: [], disabledProductIds: ['prod-2'],
        updatedAt: new Date(Date.now() - 3600000),
      });
      await db.put('products', added.id, {
        productId: added.id, itemCode: added.code, productCode: added.code,
        itemName: added.name, productName: added.name, barcode: added.barcode, itemBarcode: added.barcode,
        packagingSpecification: '24 X 450G', unitPrice: 9.5, brandName: 'TENTEN', brand: 'TENTEN',
        departmentName: 'GROCERY', mainCategoryName: 'GROCERY', sortOrder: 0, isVisible: true,
        createdAt: new Date(),
      });
      await page.reload();
      await B.enableSemantics(page);
      await admin.waitForShell(page);
      await admin.goToPage(page, 'Score Sheets');
      await admin.pickDropdown(page, 'Choose retailer', retailer.name);
      await B.see(page, /NEW ARRIVAL OAT \(24P X 450G\), selected, visible on mobile/, { timeout: 20000 });
      await page.getByRole('button', { name: 'Save sheet', exact: true }).click();
      await B.see(page, /Retailer score sheet settings saved/);
      const sheet = await db.get('retailer_score_sheet_settings', retailer.id);
      assert.ok(!sheet.disabledProductIds.includes(added.id), 'the product added after the last save is not disabled');
      assert.ok(sheet.visibleProductIds.includes(added.id), 'the product added after the last save is on the sheet');
      assert.ok(sheet.disabledProductIds.includes('prod-2'), 'a product that was disabled stays disabled');
    });

    await t.step('saving a sheet keeps a product created while the editor was open on', async () => {
      const page = pageSession.page;
      const retailer = RETAILERS[1];
      const created = { id: 'prod-while-open', name: 'WHILE OPEN CHOCO (12P X 200G)', code: 'R004-ORG-005', barcode: '9555592203002' };
      const before = await db.get('retailer_score_sheet_settings', retailer.id);
      await db.put('products', created.id, {
        productId: created.id, itemCode: created.code, productCode: created.code,
        itemName: created.name, productName: created.name, barcode: created.barcode, itemBarcode: created.barcode,
        packagingSpecification: '12 X 200G', unitPrice: 7.5, brandName: 'TENTEN', brand: 'TENTEN',
        departmentName: 'GROCERY', mainCategoryName: 'GROCERY', sortOrder: 0, isVisible: true,
        createdAt: new Date(),
      });
      assert.equal(await page.getByLabel(/WHILE OPEN CHOCO/).count(), 0, 'the open editor does not show the new product');
      await page.getByRole('button', { name: 'Save sheet', exact: true }).click();
      await B.see(page, /Retailer score sheet settings saved/);
      const sheet = await db.waitForDoc('retailer_score_sheet_settings', retailer.id, (s) => JSON.stringify(s.updatedAt) !== JSON.stringify(before.updatedAt), { timeout: 15000, label: 'sheet saved' });
      assert.ok(sheet.visibleProductIds.includes(created.id), 'the product created while the editor was open is on the sheet');
      assert.ok(!sheet.disabledProductIds.includes(created.id), 'the product created while the editor was open is not disabled');
      assert.ok(sheet.disabledProductIds.includes('prod-2'), 'a product that was disabled stays disabled');
    });

    await t.step('a second save on the same screen keeps a product created while the editor was open on', async () => {
      const page = pageSession.page;
      const retailer = RETAILERS[1];
      const created = { id: 'prod-two-saves', name: 'TWO SAVES WAFER (10P X 100G)', code: 'R004-ORG-006', barcode: '9555592203019' };
      const savedSheet = (previous) => db.waitForDoc('retailer_score_sheet_settings', retailer.id, (s) => JSON.stringify(s.updatedAt) !== JSON.stringify(previous.updatedAt), { timeout: 15000, label: 'sheet saved' });
      await db.put('retailer_score_sheet_settings', retailer.id, {
        retailerId: retailer.id, retailerName: retailer.name, sheetName: `${retailer.name} Score Sheet`,
        visibleProductIds: (await db.list('products')).map((product) => product.id), hiddenProductIds: [], disabledProductIds: [],
        updatedAt: new Date(Date.now() - 3600000),
      });
      await page.reload();
      await B.enableSemantics(page);
      await admin.waitForShell(page);
      await admin.goToPage(page, 'Score Sheets');
      await admin.pickDropdown(page, 'Choose retailer', retailer.name);
      await page.getByRole('button', { name: 'Deselect all', exact: true }).waitFor({ timeout: 20000 });
      await db.put('products', created.id, {
        productId: created.id, itemCode: created.code, productCode: created.code,
        itemName: created.name, productName: created.name, barcode: created.barcode, itemBarcode: created.barcode,
        packagingSpecification: '10 X 100G', unitPrice: 4.5, brandName: 'TENTEN', brand: 'TENTEN',
        departmentName: 'GROCERY', mainCategoryName: 'GROCERY', sortOrder: 0, isVisible: true,
        createdAt: new Date(),
      });
      const seeded = await db.get('retailer_score_sheet_settings', retailer.id);
      await page.getByRole('button', { name: 'Deselect all', exact: true }).click();
      await page.getByRole('button', { name: 'Save sheet', exact: true }).click();
      await B.see(page, /Retailer score sheet settings saved/);
      const emptied = await savedSheet(seeded);
      assert.deepEqual(emptied.visibleProductIds, [], 'deselecting every product empties the visible list');
      await page.getByRole('button', { name: 'Select all', exact: true }).click();
      await page.getByRole('button', { name: 'Save sheet', exact: true }).click();
      await B.see(page, /Retailer score sheet settings saved/);
      const sheet = await savedSheet(emptied);
      assert.ok(sheet.visibleProductIds.includes('prod-1'), 'the ticked product is on the sheet');
      assert.ok(sheet.visibleProductIds.includes(created.id), 'the product created while the editor was open is still on the sheet after the second save');
      assert.ok(!sheet.disabledProductIds.includes(created.id), 'the product created while the editor was open is not disabled');
    });
  },
};
