'use strict';

const B = require('./browser.cjs');

async function waitForShell(page) {
  await page.getByRole('button', { name: 'All Orders' }).first().waitFor({ timeout: 60000 });
}

async function waitForSupervisorShell(page) {
  await page.getByRole('button', { name: 'Team Overview' }).first().waitFor({ timeout: 60000 });
}

async function waitForBranchManagerShell(page) {
  await page.getByRole('button', { name: /Branch Routes/ }).first().waitFor({ timeout: 60000 });
}

async function isInView(page, locator) {
  if (!(await locator.count())) return false;
  const box = await locator.boundingBox();
  return Boolean(box) && box.height >= 24 && box.y >= 0 && box.y + box.height <= page.viewportSize().height;
}

const escapeRegExp = (text) => text.replace(/[\\^$.*+?()[\]{}|]/g, '\\$&');

async function scrollRailTo(page, locator) {
  if (await isInView(page, locator)) return;
  const viewport = page.viewportSize();
  await page.mouse.move(100, viewport.height / 2);
  for (const dy of [-10000, 300, 300, 300, 300, 300, 300]) {
    await page.mouse.wheel(0, dy);
    await page.waitForTimeout(250);
    if (await isInView(page, locator)) break;
  }
}

async function goToPage(page, label) {
  const name = typeof label === 'string' ? new RegExp(`^${escapeRegExp(label)}(, .*)?$`) : label;
  const button = page.getByRole('button', { name }).first();
  const toggles = page.getByRole('button', { name: /, \d+ pages, collapsed$/ });
  const expanded = page.getByRole('button', { name: /, \d+ pages, expanded$/, disabled: false });
  for (let guard = 0; guard < 12 && !(await button.count()) && (await expanded.count()); guard += 1) {
    await scrollRailTo(page, expanded.first());
    await expanded.first().click();
    await page.waitForTimeout(250);
  }
  for (let guard = 0; guard < 12 && !(await button.count()); guard += 1) {
    if (!(await toggles.count())) {
      await page.mouse.move(100, page.viewportSize().height / 2);
      await page.mouse.wheel(0, 300);
      await page.waitForTimeout(250);
      continue;
    }
    await scrollRailTo(page, toggles.first());
    await toggles.first().click();
    await page.waitForTimeout(250);
  }
  await scrollRailTo(page, button);
  await button.click();
}

async function openOrder(page, orderId) {
  await page.getByRole('button', { name: new RegExp(`^(Order )?${orderId}`) }).click();
  await page.getByRole('button', { name: 'Approve', exact: true }).waitFor({ timeout: 20000 });
}

async function approveOpenOrder(page) {
  await page.getByRole('button', { name: 'Approve', exact: true }).click();
}

async function orderRowCount(page, orderId) {
  return page.getByRole('button', { name: new RegExp(`^(Order )?${orderId}`) }).count();
}

async function waitForOrderRow(page, orderId, { timeout = 60000 } = {}) {
  await page.getByRole('button', { name: new RegExp(`^(Order )?${orderId}`) }).first().waitFor({ timeout });
  return Date.now();
}

async function waitForRowStatus(page, orderId, status) {
  await page.getByRole('button', { name: new RegExp(`^${orderId}.*${status}(\\s+Price (checked|mismatch|not verifiable))?$`, 'i') }).waitFor({ timeout: 20000 });
}

async function pickDropdown(page, current, option) {
  await page.getByRole('button', { name: current }).first().click();
  await page.getByRole('menuitem', { name: option }).first().click();
}

async function chooseOption(page, field, option) {
  await page.getByRole('button', { name: field }).last().click();
  await page.getByRole('menuitem', { name: option, exact: true }).first().click();
}

async function createBranch(page, name) {
  await goToPage(page, 'Branches');
  await B.see(page, 'Add Branch');
  await B.fillField(page, page.getByRole('textbox').first(), name);
  await page.getByRole('button', { name: 'Save Branch' }).click();
  await B.see(page, 'Branch added.');
}

async function semanticsLines(page) {
  return page.evaluate(() => Array.from(document.querySelectorAll('flt-semantics'))
    .map((n) => (n.getAttribute('aria-label') || n.textContent || '').trim()).filter(Boolean));
}

const INVITE_CODE = /[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}-[0-9A-HJKMNP-TV-Z]{4}/;

async function createUser(page, { keepDialog = false, expectDialog = true, ...fields }) {
  await fillUserForm(page, fields);
  await submitUserForm(page);
  if (!expectDialog) return null;
  await B.see(page, 'Invitation created', { timeout: 30000 });
  const dialog = await readInvitationDialog(page);
  if (!keepDialog) await closeInvitationDialog(page);
  return dialog;
}

async function fillUserForm(page, { name, email = '', phone = '', code = '', role, branchName, supervisorOption }) {
  await goToPage(page, 'Role Assignment');
  await B.see(page, 'Create User');
  await collapseInvitations(page);
  const boxes = page.getByRole('textbox');
  await scrollFormTop(page);
  if (code) await B.fillField(page, boxes.nth(0), code);
  await B.fillField(page, boxes.nth(1), name);
  if (email) await B.fillField(page, boxes.nth(2), email);
  if (phone) await B.fillField(page, boxes.nth(3), phone);
  const pickInForm = async (current, option) => {
    await scrollFormTop(page);
    if (typeof option === 'string' && await page.getByRole('button', { name: option, exact: true }).count()) return;
    const trigger = page.getByRole('button', { name: current }).first();
    await B.scrollIntoView(page, trigger, { minHeight: 20, bottomInset: 0, pointerY: 0.8 });
    await trigger.click();
    await page.getByRole('menuitem', { name: option }).first().click();
  };
  if (role) await pickInForm(/^Salesman$/, role);
  if (branchName) await pickInForm(/Select a branch/, branchName);
  if (supervisorOption) await pickInForm(/^Not linked/, supervisorOption);
}

async function createUserButton(page) {
  const create = page.getByRole('button', { name: 'Create User', exact: true });
  await B.scrollIntoView(page, create, { minHeight: 20, bottomInset: 0, pointerY: 0.8 });
  return create;
}

async function submitUserForm(page) {
  await (await createUserButton(page)).click();
}

async function searchDirectory(page, text) {
  const box = await page.getByRole('textbox', { name: /Search by name/ }).elementHandle({ timeout: 20000 });
  for (let attempt = 0; attempt < 5; attempt += 1) {
    await box.click();
    await page.keyboard.press('Control+A');
    await page.keyboard.press('Backspace');
    await page.keyboard.type(text, { delay: 20 });
    if ((await box.inputValue()) === text) return;
    await page.waitForTimeout(400);
  }
  throw new Error('could not enter text into the directory search reliably');
}

async function collapseInvitations(page) {
  const refresh = page.getByRole('button', { name: 'Refresh', exact: true });
  if (!(await refresh.count())) return;
  await B.semantic(page, /^Invitations/).click();
  await refresh.waitFor({ state: 'detached', timeout: 10000 });
}

async function scrollFormTop(page) {
  await page.mouse.move(550, 800);
  await page.mouse.wheel(0, -5000);
  await page.waitForTimeout(300);
}

async function readInvitationDialog(page) {
  const lines = await semanticsLines(page);
  await page.getByRole('button', { name: 'Copy code', exact: true }).click();
  let code = '';
  for (let i = 0; i < 20 && !INVITE_CODE.test(code); i += 1) {
    code = (await page.evaluate(() => navigator.clipboard.readText().catch(() => ''))).trim();
    if (!INVITE_CODE.test(code)) await page.waitForTimeout(250);
  }
  if (!INVITE_CODE.test(code)) throw new Error(`"Copy code" put "${code}" on the clipboard, not a code`);
  const values = await page.evaluate(() => Array.from(document.querySelectorAll('input,textarea')).map((e) => e.value));
  const signInId = values.find((v) => /^\S+@\S+$/.test(v)) || null;
  return { code, signInId, lines, values };
}

const grantClipboard = { permissions: ['clipboard-read', 'clipboard-write'] };

async function closeInvitationDialog(page) {
  await page.getByRole('button', { name: 'Done', exact: true }).click();
  await page.getByRole('button', { name: 'Done', exact: true }).waitFor({ state: 'detached', timeout: 10000 });
}

async function openRedeemForm(page, url) {
  await B.openApp(page, url);
  await page.getByRole('button', { name: 'Have an invitation code?' }).waitFor({ timeout: 60000 });
  await page.getByRole('button', { name: 'Have an invitation code?' }).click();
  await B.see(page, 'Redeem your invitation');
}

async function submitRedeemForm(page, { code, check, password }) {
  const inputs = page.locator('input');
  await B.fillField(page, inputs.nth(0), code);
  await B.fillField(page, inputs.nth(1), check);
  await B.fillField(page, inputs.nth(2), password);
  await B.fillField(page, inputs.nth(3), password);
  await page.getByRole('button', { name: /^(Redeem invitation|Set password and sign in)$/ }).click();
}

async function openInvitations(page) {
  await goToPage(page, 'Role Assignment');
  const refresh = page.getByRole('button', { name: 'Refresh', exact: true });
  await B.see(page, /^Invitations/);
  if (!(await refresh.count())) await B.semantic(page, /^Invitations/).click();
  await refresh.waitFor({ timeout: 10000 });
  await refresh.click();
}

async function createProduct(page, fields, { expectToast = 'Product item saved.' } = {}) {
  await goToPage(page, 'Products');
  await page.getByRole('button', { name: 'Add product' }).click();
  const box = (label) => page.getByRole('textbox', { name: new RegExp(`^${label}\\b`) }).first();
  await B.fillField(page, box('Department'), fields.department);
  await B.fillField(page, box('Main Category'), fields.category);
  await B.fillField(page, box('Product'), fields.name);
  await B.fillField(page, box('Brand'), fields.brand);
  await B.fillField(page, box('Product Code'), fields.code);
  await B.fillField(page, box('Unit Price'), String(fields.price));
  await page.getByRole('button', { name: 'Save', exact: true }).click();
  await B.see(page, expectToast);
}

async function setProductVisibility(page, productName, action = 'Hide', { expectToast } = {}) {
  await goToPage(page, 'Products');
  const escaped = productName.replace(/[()]/g, '\\$&');
  const row = page.getByRole('button', { name: new RegExp(`^Product ${escaped}`) }).first();
  await row.waitFor({ timeout: 20000 });
  await row.hover();
  await page.getByRole('button', { name: new RegExp(`^${action} ${escaped}`) }).click();
  await B.see(page, expectToast || (action === 'Hide' ? 'Hid 1 product' : 'Showed 1 product'));
}

async function setUserStatus(page, { code, name }, action, { expectToast } = {}) {
  await goToPage(page, 'Role Assignment');
  await collapseInvitations(page);
  const clear = page.getByRole('button', { name: 'Clear search', exact: true });
  if (await clear.count()) await clear.click();
  await searchDirectory(page, code);
  await page.getByRole('button', { name: action, exact: true }).first().click();
  await B.see(page, `${action} ${name}?`);
  await page.getByRole('button', { name: action, exact: true }).last().click();
  await B.see(page, expectToast || (action === 'Suspend'
    ? `${name} is suspended and blocked from signing in.`
    : `${name} is active again and can sign in.`));
}

async function sidebarLabels(page, { railWidth = 250 } = {}) {
  const seen = new Set();
  const collect = async () => {
    const names = await page.evaluate((width) => Array.from(document.querySelectorAll('flt-semantics[role="button"]'))
      .filter((n) => { const r = n.getBoundingClientRect(); return r.width > 0 && r.height > 0 && r.left < width && r.right <= width + 4; })
      .map((n) => (n.getAttribute('aria-label') || n.textContent || '').trim().split(/\r?\n/)[0]), railWidth);
    for (const name of names) if (name) seen.add(name);
  };
  const viewport = page.viewportSize();
  await page.mouse.move(Math.min(120, railWidth / 2), viewport.height / 2);
  await page.mouse.wheel(0, -10000);
  await page.waitForTimeout(250);
  await collect();
  for (let i = 0; i < 12; i += 1) {
    const before = seen.size;
    await page.mouse.wheel(0, 300);
    await page.waitForTimeout(250);
    await collect();
    if (i > 3 && seen.size === before) break;
  }
  await page.mouse.wheel(0, -10000);
  await page.waitForTimeout(250);
  return [...seen];
}

async function openPageKey(page, key) {
  await page.evaluate((k) => {
    history.pushState(history.state, '', `#/${k}`);
    window.dispatchEvent(new PopStateEvent('popstate', { state: history.state }));
  }, key);
  await page.waitForTimeout(500);
}

module.exports = {
  sidebarLabels, openPageKey,
  setUserStatus, fillUserForm, submitUserForm, createUserButton,
  setProductVisibility, createProduct,
  orderRowCount, waitForOrderRow, waitForRowStatus, waitForShell, goToPage, openOrder, approveOpenOrder,
  pickDropdown, chooseOption, createBranch, createUser, waitForSupervisorShell, waitForBranchManagerShell,
  searchDirectory, collapseInvitations, scrollFormTop, semanticsLines, grantClipboard, readInvitationDialog, closeInvitationDialog, openRedeemForm, submitRedeemForm, openInvitations,
};
