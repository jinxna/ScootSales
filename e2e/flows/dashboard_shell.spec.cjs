'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');

const SHOP = '华美超市 🛒 Kuching';
const FONT_HOSTS = /(^|\.)fonts\.(gstatic|googleapis)\.com$/;

function expect(condition, what) {
  if (!condition) throw new Error(what);
}

async function fontHostRequests(session) {
  return [...session.blocked, ...(session.requests || [])].filter((url) => FONT_HOSTS.test(new URL(url).hostname));
}

async function openHelp(page) {
  await page.getByRole('button', { name: 'Help and questions' }).first().click();
  await B.see(page, 'Search questions');
}

async function closeHelp(page) {
  await page.getByRole('button', { name: 'Close', exact: true }).first().click();
  await page.waitForTimeout(400);
}

async function searchHelp(page, text) {
  const box = page.getByRole('textbox', { name: /Search questions/ });
  await B.fillField(page, box, text);
  await page.waitForTimeout(500);
}

module.exports = {
  name: 'dashboard_shell',
  platformApi: false,
  async run(t) {
    const { db, accounts, seed } = t;
    const view = { width: 1440, height: 900 };
    let s;

    await t.step('seed a shop with a Chinese name and an emoji, and one order for it', async () => {
      await db.put('retailers', 'ret-cn', {
        retailerId: 'ret-cn', retailerName: SHOP, name: SHOP, area: 'Kuching', branchId: seed.branch.id, status: 'active',
        address: 'Kuching', latitude: 1.5535, longitude: 110.3593, coordinateStatus: 'verified',
        assignedSalesmanCode: accounts.salesman.code, assignedSalesmanUid: seed.uids.salesman,
      });
      const at = new Date();
      await db.put('orders', 'ORD-E2E-CN', {
        orderId: 'ORD-E2E-CN', uid: seed.uids.salesman, userUid: seed.uids.salesman, salesmanUid: seed.uids.salesman,
        salesmanEmail: accounts.salesman.email, salesmanName: accounts.salesman.name, salesmanCode: accounts.salesman.code,
        branchId: seed.branch.id, retailerId: 'ret-cn', retailerName: SHOP, status: 'submitted',
        items: [{ productId: 'prod-1', name: 'ORGANIC APPLE CIDER VINEGAR', quantity: 1, price: 28.12 }],
        totalProducts: 1, totalBoxes: 1, totalPrice: 28.12, submittedAt: at, createdAt: at,
      });
    });

    await t.step('admin sees the new shell: rail groups, Ctrl K search, scope, Scout, help, account', async () => {
      s = await t.session('admin', { viewport: view });
      s.requests = [];
      s.page.on('request', (request) => s.requests.push(request.url()));
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      await B.see(s.page, /Main menu/);
      await B.see(s.page, /Jump to a page/);
      await B.see(s.page, /Scope: All branches/);
      await B.see(s.page, /^Scout/);
      await B.see(s.page, 'Help and questions');
      await B.see(s.page, /Account menu, E2E Admin/);
      await B.see(s.page, /Catalogue, \d+ pages, collapsed/);
      await s.page.waitForTimeout(1500);
      await t.shot(s, 'admin-dashboard');
    });

    await t.step('Ctrl K opens the page search', async () => {
      await s.page.keyboard.press('Control+K');
      await B.see(s.page, 'Jump to a page…');
      await s.page.keyboard.press('Escape');
      await s.page.waitForTimeout(400);
    });

    await t.step('All Orders shows a paged table and the Chinese shop name', async () => {
      await admin.goToPage(s.page, 'All Orders');
      await B.see(s.page, /ORD-E2E-CN/);
      await B.see(s.page, /orders? loaded/);
      await B.see(s.page, /50 per page/);
      await s.page.waitForTimeout(2500);
      await t.shot(s, 'admin-orders');
    });

    await t.step('a rail group collapses and opens again while one of its pages is open', async () => {
      await admin.goToPage(s.page, 'Products');
      await B.see(s.page, /Manage the product catalogue/);
      const toggle = s.page.getByRole('button', { name: /^Catalogue, \d+ pages, expanded$/ });
      await toggle.click();
      await B.see(s.page, /Catalogue, \d+ pages, collapsed/);
      expect(await s.page.getByRole('button', { name: /^Products/ }).count() === 0, 'Products is still listed after the group was collapsed');
      await s.page.getByRole('button', { name: /^Catalogue, \d+ pages, collapsed$/ }).click();
      await B.see(s.page, /Catalogue, \d+ pages, expanded/);
      expect(await s.page.getByRole('button', { name: /^Products/ }).count() > 0, 'Products is not listed after the group was opened');
    });

    await t.step('no request goes to fonts.gstatic.com or fonts.googleapis.com', async () => {
      const calls = await fontHostRequests(s);
      expect(calls.length === 0, `font host requests: ${calls.join(', ')}`);
      const own = s.requests.filter((url) => url.includes('/fonts/s/'));
      expect(own.length > 0, 'no fallback font was fetched from this origin');
    });

    await t.step('Route Planner opens with the bright map', async () => {
      await admin.goToPage(s.page, 'Route Planner');
      await s.page.waitForTimeout(3500);
      await t.shot(s, 'admin-route-planner');
    });

    await t.step('Help opens the questions for admins; search finds the status answers', async () => {
      await openHelp(s.page);
      await B.see(s.page, 'What can each person do when the company is suspended?');
      await t.shot(s, 'admin-help');
      await searchHelp(s.page, 'change our plan');
      await B.see(s.page, 'How do we change our plan?');
      await searchHelp(s.page, 'suspended');
      await B.see(s.page, 'What can each person do when the company is suspended?');
      expect(await s.page.getByText('How do we change our plan?').count() === 0, 'plan answer shown for the search "suspended"');
      await searchHelp(s.page, 'zzzzzz');
      await B.see(s.page, 'No answers found');
      await searchHelp(s.page, 'change our plan');
      await s.page.getByRole('button', { name: /How do we change our plan\?/ }).first().click();
      await B.see(s.page, 'A plan can only change to a larger one.');
      await closeHelp(s.page);
    });

    await t.step('help works with the keyboard only: Tab to a question, Enter opens it', async () => {
      await openHelp(s.page);
      await s.page.getByRole('textbox', { name: /Search questions/ }).first().focus();
      await s.page.keyboard.press('Tab');
      await s.page.keyboard.press('Enter');
      await B.see(s.page, 'Active: everything works.');
      await closeHelp(s.page);
    });

    await t.step('the account menu opens the same help page', async () => {
      await s.page.getByRole('button', { name: /Account menu, E2E Admin/ }).first().click();
      await s.page.getByRole('button', { name: 'Help and questions' }).last().click();
      await B.see(s.page, 'Search questions');
      await closeHelp(s.page);
    });

    await t.step('supervisor lands on Team Overview and sees supervisor answers only', async () => {
      await s.page.keyboard.press('Escape');
      await s.page.waitForTimeout(500);
      for (let attempt = 0; attempt < 4 && !(await B.semantic(s.page, /^Sign out$/).count()); attempt += 1) {
        await s.page.getByRole('button', { name: /Account menu, E2E Admin/ }).first().click();
        await s.page.waitForTimeout(800);
      }
      await B.semantic(s.page, /^Sign out$/).click();
      await B.see(s.page, /Sign In/);
      await B.loginAdmin(s.page, s.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(s.page);
      await s.page.waitForTimeout(1500);
      await t.shot(s, 'supervisor-home');
      await openHelp(s.page);
      await B.see(s.page, 'What can each person do when the company is suspended?');
      await searchHelp(s.page, 'approve orders');
      await B.see(s.page, 'Who can approve orders and special requests?');
      await searchHelp(s.page, 'change our plan');
      await B.see(s.page, 'No answers found');
      expect(await s.page.getByText('How do we change our plan?').count() === 0, 'admin-only answer shown to a supervisor');
      await closeHelp(s.page);
    });

    await t.step('team orders open for the supervisor', async () => {
      await admin.goToPage(s.page, 'Team Orders');
      await B.see(s.page, /orders? loaded|No orders found/);
      await s.page.waitForTimeout(1500);
      await t.shot(s, 'supervisor-orders');
    });

    await t.step('branch manager lands on the branch overview', async () => {
      await s.page.getByRole('button', { name: /Account menu, E2E Supervisor/ }).first().click();
      await B.semantic(s.page, /^Sign out$/).click();
      await B.see(s.page, /Sign In/);
      await B.loginAdmin(s.page, s.url, accounts.branchManager.email);
      await admin.waitForBranchManagerShell(s.page);
      await s.page.waitForTimeout(1500);
      await t.shot(s, 'branch-manager-home');
    });
  },
};
