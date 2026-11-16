'use strict';
const {
  Timestamp,
  deleteDoc,
  doc,
  getDoc,
  serverTimestamp,
  setDoc,
  updateDoc,
  writeBatch,
} = require('firebase/firestore');

const SHAPES = ['uid', 'linked', 'v2'];
const BUDGET = /maximum of 1000 expressions/i;

const AUDIT_ACTORS = {
  admin: { uid: 'ba-admin', role: 'admin', branchId: 'B1' },
  developer: { uid: 'ba-dev', role: 'developer' },
  supervisor: {
    uid: 'ba-sup', role: 'supervisor', assignedSalesmanCodes: ['S001'],
    branchId: 'B1', employeeCode: 'SV01',
  },
  manager: { uid: 'ba-mgr', role: 'branch_manager', branchId: 'B1' },
  salesman: { uid: 'ba-sales', role: 'salesman', employeeCode: 'S001', branchId: 'B1' },
  suspended: { uid: 'ba-sus', role: 'admin', status: 'suspended' },
  unlinked: { uid: 'ba-unl', role: 'admin', unlinked: true },
  nullFlag: { uid: 'ba-null', role: 'admin', isActive: null },
  noStatus: { uid: 'ba-nost', role: 'admin', status: null },
};
const ACTOR_KEYS = Object.keys(AUDIT_ACTORS);

const PERMISSIONS_OF = {
  unlinked: { v2: 'admin' },
  nullFlag: { v2: 'admin' },
  noStatus: { uid: 'admin', linked: 'admin' },
};

const present = (o) => Object.fromEntries(
  Object.entries(o).filter(([k, v]) => !(k === 'status' && v === null)),
);

function legacyRole(shape, key, role) {
  return shape === 'linked' && key === 'salesman' ? 'sales representative' : role;
}

function v2Access(uid, base, userDocId) {
  return {
    accessVersion: 2,
    uid,
    role: base.role,
    ...(base.status === null ? {} : { status: base.status }),
    branchId: base.branchId || '',
    employeeCode: base.employeeCode || '',
    userDocId,
    ...(base.role === 'salesman' ? { supervisorUid: 'ba-sup' } : {}),
    ...(base.role === 'supervisor'
      ? { assignedSalesmanCodes: base.assignedSalesmanCodes }
      : {}),
  };
}

async function seedAuditActors(db, shape) {
  for (const [key, a] of Object.entries(AUDIT_ACTORS)) {
    const { unlinked, uid, ...profile } = a;
    const docId = `${key}@ba.test`;
    const base = { status: 'active', ...profile };
    const legacy = present({ ...base, role: legacyRole(shape, key, base.role) });
    if (shape === 'uid') {
      if (!unlinked) await setDoc(doc(db, 'users', uid), { ...legacy, uid });
      continue;
    }
    if (!unlinked) await setDoc(doc(db, 'users', docId), { ...legacy, uid });
    await setDoc(
      doc(db, 'user_access', uid),
      shape === 'linked'
        ? { ...legacy, uid, user_group: legacy.role, userDocId: docId }
        : v2Access(uid, base, docId),
    );
  }
}

function expectedAllowed(row, key, shape) {
  const as = (PERMISSIONS_OF[key] || {})[shape];
  if ((row.deny?.[shape] || []).includes(key)) return false;
  return row.allow.includes(key) || Boolean(as && row.allow.includes(as));
}

function auditedOrderDelete(db, actor, id, previousStatus) {
  const batch = writeBatch(db);
  batch.set(doc(db, 'order_audit_logs', id), {
    action: 'delete', orderDocumentId: id, orderId: id, previousStatus,
    actorUid: actor.uid, actorRole: actor.role, retailerId: 'retailer-1', salesmanUid: 'ba-sales',
    occurredAt: serverTimestamp(),
  });
  batch.delete(doc(db, 'orders', id));
  return batch.commit();
}

function buildAuditRows({ specialRequest, newVisit }) {
  const ADMINS = ['admin', 'developer'];
  const ALL = ACTOR_KEYS;
  const MEMBERS = ['admin', 'developer', 'supervisor', 'manager', 'salesman'];
  const DASH = ['admin', 'developer', 'supervisor', 'manager'];
  const ROUTE_WRITERS = ['admin', 'developer', 'supervisor'];

  const product = (overrides = {}) => ({
    productId: 'pa-1', departmentId: 'beverage', categoryId: 'beverage_juice',
    departmentName: 'Beverage', departmentManagerName: 'Catalogue Team',
    mainCategoryName: 'Juice', categoryName: 'Juice', subCategoryName: 'Pure',
    itemName: 'Orange Juice', productName: 'Orange Juice', productFlavor: 'Orange',
    flavor: 'Orange', itemCode: 'OJ-01', productCode: 'OJ-01', sku: 'OJ-01',
    barcode: '9551000000015', itemBarcode: '9551000000015', packingSize: '12 x 1L',
    unitPrice: 12.5, price: 12.5, priceGuide: 12.5, uom: 'ctn', uomLabel: 'ctn',
    unitOfMeasure: 'ctn', sortOrder: 1, brandName: 'TENTEN', isVisible: true,
    status: 'active', mobileDisplayMode: 'textOnly',
    createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
    ...overrides,
  });
  const storedProduct = () => product({ createdAt: Timestamp.now(), updatedAt: Timestamp.now() });
  const hiddenProduct = (overrides = {}) => product({ isVisible: false, status: 'hidden', ...overrides });
  const editedProduct = () => Object.fromEntries([
    ...Object.entries(storedProduct()).filter(([k]) => k !== 'isVisible' && k !== 'status').map(([k, v]) => [
      k,
      k === 'createdAt' || k === 'updatedAt' ? serverTimestamp()
        : typeof v === 'number' ? v + 1
          : typeof v === 'boolean' ? !v
            : `${v}-edited`,
    ]),
    ['priceUpdatedAt', serverTimestamp()],
  ]);

  const moduleRows = [
    ['products', storedProduct(), () => hiddenProduct(), editedProduct()],
    ['departments', { name: 'D' }, () => ({ name: 'D' }), { name: 'D2' }],
    ['categories', { name: 'C' }, () => ({ name: 'C' }), { name: 'C2' }],
    ['score_sheets', { name: 'S' }, () => ({ name: 'S' }), { name: 'S2' }],
    ['retailer_score_sheet_settings', { name: 'S' }, () => ({ name: 'S' }), { name: 'S2' }],
    ['retailer_score_sheet_items', { name: 'S' }, () => ({ name: 'S' }), { name: 'S2' }],
    ['department_pic_assignments', { name: 'P' }, () => ({ name: 'P' }), { name: 'P2' }],
    ['website_pages', { title: 'W' }, () => ({ title: 'W' }), { title: 'W2' }],
  ];
  const rows = [];
  for (const [col, stored, fresh, patch] of moduleRows) {
    rows.push(
      { col, op: 'read', stored, allow: MEMBERS },
      { col, op: 'create', fresh, allow: ADMINS },
      { col, op: 'update', stored, patch, allow: ADMINS },
      { col, op: 'delete', stored, allow: col === 'products' ? [] : ADMINS },
    );
  }
  rows.push(
    {
      col: 'products', op: 'create',
      fresh: () => ({ productId: 'minimal-product', itemName: 'Orange Juice', isVisible: false, status: 'hidden' }),
      allow: ADMINS, label: 'minimal product create',
    },
    {
      col: 'products', op: 'update', stored: storedProduct(),
      patch: { unitPrice: 13, updatedAt: serverTimestamp(), priceUpdatedAt: serverTimestamp() },
      allow: ADMINS, label: 'normal product form edit',
    },
  );
  const userStored = { uid: 'ba-x', role: 'salesman', status: 'active', employeeCode: 'S001', branchId: 'B1' };
  const routeStored = {
    status: 'draft', createdByUid: 'x', salesmanCode: 'S001', salesmanUid: 'ba-sales', branchId: 'B1',
    weekStart: Timestamp.fromDate(new Date('2026-06-15T00:00:00Z')),
  };
  const scoped = { salesmanCode: 'S001', salesmanUid: 'ba-sales', branchId: 'B1' };
  rows.push(
    { col: 'branches', op: 'read', stored: { name: 'B' }, allow: MEMBERS },
    { col: 'branches', op: 'create', fresh: () => ({ name: 'B' }), allow: ADMINS },
    { col: 'branches', op: 'update', stored: { name: 'B' }, patch: { name: 'B2' }, allow: ADMINS },
    { col: 'branches', op: 'delete', stored: { name: 'B' }, allow: ADMINS },
    { col: 'retailers', op: 'read', stored: { retailerName: 'R', branchId: 'B1' }, allow: MEMBERS },
    {
      col: 'retailers', op: 'create', fresh: () => ({ retailerName: 'R', branchId: 'B1' }),
      allow: ADMINS,
    },
    {
      col: 'retailers', op: 'update', stored: { retailerName: 'R', branchId: 'B1' },
      patch: { retailerName: 'R2' }, allow: ADMINS,
    },
    { col: 'retailers', op: 'delete', stored: { retailerName: 'R', branchId: 'B1' }, allow: [] },
    { col: 'users', op: 'read', stored: userStored, allow: [...ADMINS, 'supervisor', 'manager'] },
    {
      col: 'users', op: 'create',
      fresh: () => ({ uid: 'ba-new', role: 'salesman', status: 'active', branchId: 'B1' }),
      allow: [],
    },
    { col: 'users', op: 'update', stored: userStored, patch: { contactNumber: '123' }, allow: ADMINS },
    { col: 'users', op: 'delete', stored: userStored, allow: [] },
    { col: 'user_access', op: 'read', stored: { uid: 'ba-other', role: 'salesman', status: 'active' }, allow: ADMINS },
    { col: 'dashboard_preferences', op: 'read', stored: { layout: 'a' }, own: true, allow: MEMBERS },
    { col: 'dashboard_preferences', op: 'create', fresh: () => ({ layout: 'a' }), own: true, allow: ALL, deny: { uid: ['unlinked'] } },
    { col: 'cms_backups', op: 'read', stored: { a: 1 }, allow: ADMINS },
    { col: 'cms_backups', op: 'create', fresh: () => ({ a: 1 }), allow: ADMINS },
    { col: 'cms_backups', op: 'delete', stored: { a: 1 }, allow: ADMINS },
    { col: 'system_settings', op: 'read', stored: { a: 1 }, allow: DASH },
    { col: 'system_settings', op: 'create', fresh: () => ({ a: 1 }), allow: ADMINS },
    { col: 'purge_exports', op: 'read', stored: { a: 1 }, allow: ADMINS },
    { col: 'purge_exports', op: 'create', fresh: () => ({ a: 1 }), allow: ADMINS },
    { col: 'order_audit_logs', op: 'read', stored: { a: 1 }, allow: ADMINS },
    { col: 'system_audit_logs', op: 'read', stored: { a: 1 }, allow: ADMINS },
    {
      col: 'system_audit_logs', op: 'create',
      fresh: (a) => ({ actorUid: a.uid, createdAt: serverTimestamp(), action: 'x' }),
      allow: DASH,
    },
    { col: 'system_access_config', op: 'read', stored: { roles: {}, revision: 1 }, id: 'permission_matrix', allow: ADMINS },
    { col: 'demand_forecasts', op: 'read', stored: { a: 1 }, allow: DASH },
    { col: 'dashboard_notifications', op: 'read', stored: { roleTarget: 'supervisor', salesmanCode: 'S001', branchId: 'B1' }, allow: DASH },
    { col: 'action_centre_items', op: 'read', stored: { a: 1 }, allow: DASH },
    { col: 'notification_read_state', op: 'read', stored: { readThroughAt: Timestamp.now() }, own: true, allow: [...DASH, 'salesman'] },
    { col: 'ai_runs', op: 'read', stored: { a: 1 }, allow: ADMINS },
    { col: 'weekly_ai_summaries', op: 'read', stored: { scopeType: 'branch', scopeKey: 'B1' }, allow: [...ADMINS, 'manager'] },
    {
      col: 'weekly_ai_summaries', op: 'read', stored: { scopeType: 'salesman', scopeKey: 'S001' },
      allow: [...ADMINS, 'supervisor'], label: 'salesman-scoped summary',
    },
    { col: 'ai_insights', op: 'read', stored: scoped, allow: DASH },
    { col: 'retailer_priority_rankings', op: 'read', stored: scoped, allow: DASH },
    { col: 'visit_briefs', op: 'read', stored: scoped, allow: [...DASH, 'salesman'] },
    { col: 'conversation_outcomes', op: 'read', stored: scoped, allow: [...DASH, 'salesman'] },
    { col: 'notification_logs', op: 'read', stored: scoped, allow: [...DASH, 'salesman'] },
    { col: 'notification_logs', op: 'create', fresh: () => ({ title: 't' }), allow: DASH },
    {
      col: 'notification_logs', op: 'create', fresh: (a) => ({ title: 't', salesmanUid: a.uid }),
      allow: [...ADMINS, 'salesman'], label: 'own activity record',
    },
    { col: 'notification_logs', op: 'delete', stored: { a: 1 }, allow: ADMINS },
    { col: 'notifications', op: 'read', stored: scoped, allow: [...DASH, 'salesman'] },
    { col: 'notifications', op: 'create', fresh: () => ({ title: 't' }), allow: DASH },
    { col: 'notifications', op: 'delete', stored: { a: 1 }, allow: ADMINS },
    { col: 'visit_logs', op: 'read', stored: scoped, allow: [...DASH, 'salesman'] },
    { col: 'visit_logs', op: 'delete', stored: { a: 1 }, allow: ADMINS },
    { col: 'live_tracking', op: 'delete', stored: { a: 1 }, allow: ADMINS },
    { col: 'route_plans', op: 'delete', stored: { status: 'draft' }, allow: ADMINS },
    { col: 'route_plans', op: 'read', stored: routeStored, allow: DASH },
    {
      col: 'route_plans', op: 'read', stored: { ...routeStored, status: 'published', salesmanUid: 'ba-sales' },
      allow: [...DASH, 'salesman'], label: 'own published route',
    },
    {
      col: 'route_plans', op: 'create',
      fresh: (a) => ({
        status: 'draft', createdByUid: a.uid, salesmanCode: 'S001', salesmanUid: 'ba-sales', branchId: 'B1',
      }),
      allow: ROUTE_WRITERS,
    },
    { col: 'route_plans', op: 'update', stored: routeStored, patch: { status: 'approved' }, allow: ROUTE_WRITERS },
  );

  const specialFor = (a) => {
    const admin = a.role !== 'salesman';
    return specialRequest({
      createdByUid: a.uid,
      createdByRole: a.role,
      lastActorUid: a.uid,
      lastActorRole: a.role,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      lastActionAt: serverTimestamp(),
      status: admin ? 'pending_admin' : 'pending_supervisor',
      approvalStep: admin ? 'Admin' : 'Supervisor',
    });
  };
  rows.push(
    { col: 'gps_tracking', op: 'read', stored: scoped, allow: [...DASH, 'salesman'] },
    { col: 'live_tracking', op: 'read', stored: scoped, allow: [...DASH, 'salesman'] },
    { col: 'purchase_orders', op: 'read', stored: scoped, allow: DASH },
    { col: 'purchase_orders', op: 'delete', stored: scoped, allow: [] },
    { col: 'route_plan_progress', op: 'read', stored: { ...scoped, planId: 'p', status: 'assigned' }, allow: [...DASH, 'salesman'] },
    { col: 'route_stop_progress', op: 'read', stored: scoped, allow: [...DASH, 'salesman'] },
    {
      col: 'special_requests', op: 'read',
      stored: specialRequest({ createdByUid: 'ba-sales', lastActorUid: 'ba-sales' }),
      allow: [...DASH, 'salesman'],
    },
    { col: 'special_requests', op: 'create', fresh: specialFor, allow: [...ADMINS, 'supervisor', 'salesman'] },
    {
      col: 'special_requests', op: 'delete',
      stored: specialRequest({ createdByUid: 'ba-sales', lastActorUid: 'ba-sales' }),
      allow: ['developer'],
    },
    { col: 'visits', op: 'read', stored: { ownerUid: 'ba-sales' }, allow: ['salesman', 'admin', 'developer'] },
    {
      col: 'visits', op: 'create',
      fresh: (a) => ({ ...newVisit(a.uid), createdAt: serverTimestamp(), updatedAt: serverTimestamp() }),
      allow: ['salesman'],
    },
    {
      col: 'visits', op: 'update', stored: { ownerUid: 'ba-sales', createdAt: Timestamp.fromDate(new Date('2026-06-01T00:00:00Z')) },
      patch: { notes: 'x', updatedAt: serverTimestamp() }, allow: ['salesman'],
    },
    { col: 'visits', op: 'delete', stored: { ownerUid: 'ba-sales' }, allow: ['salesman'] },
    {
      col: 'retailers', op: 'update',
      stored: { retailerName: 'R', branchId: 'B1', assignedSalesmanId: 'S001' },
      patch: { progress: 'step1', lastSalesmanUid: 'ba-sales', updatedAt: serverTimestamp() },
      allow: [...ADMINS, 'salesman'],
      label: 'salesman progress patch',
    },
    {
      col: 'orders', op: 'delete', stored: { orderId: 'ORD-BA-DEL', salesmanUid: 'ba-sales', retailerId: 'retailer-1', status: 'submitted' },
      id: 'ORD-BA-DEL', allow: ['developer'], label: 'atomic audited delete',
      run: (db, a, id) => auditedOrderDelete(db, a, id, 'submitted'),
    },
    {
      col: 'orders', op: 'delete', stored: { orderId: 'ORD-BA-DRAFT', salesmanUid: 'ba-sales', retailerId: 'retailer-1', status: 'draft' },
      id: 'ORD-BA-DRAFT', allow: ADMINS, label: 'atomic audited draft delete',
      run: (db, a, id) => auditedOrderDelete(db, a, id, 'draft'),
    },
    {
      col: 'orders', op: 'update',
      stored: { orderId: 'ORD-BA-UPD', salesmanCode: 'S001', salesmanUid: 'ba-sales', status: 'submitted', serverPriceCheck: { status: 'ok', version: 1 }, retailerId: 'retailer-1', items: [{ productId: 'p1', quantity: 1 }], totalBoxes: 1, totalPrice: 20 },
      id: 'ORD-BA-UPD', allow: [...ADMINS, 'supervisor'], label: 'approval decision',
      run: (db, a, id) => updateDoc(doc(db, 'orders', id), {
        status: 'approved', approvedAt: serverTimestamp(), approvedByUid: a.uid,
        approvedByRole: a.role, updatedAt: serverTimestamp(),
      }),
    },
    {
      col: 'role_permission_grants', op: 'read', stored: { role: 'supervisor', grants: [], revision: 1 },
      id: 'supervisor', allow: [...ADMINS, 'supervisor'], label: 'own role copy',
    },
    {
      col: 'retailer_score_sheet_settings', op: 'update', stored: { retailerId: 'ba-ret', sheetName: 'S' },
      id: 'ba-ret', patch: { sheetName: 'X' }, allow: [...ADMINS, 'supervisor', 'manager'], label: 'scoped shop edit',
      seed: async (db) => {
        await setDoc(doc(db, 'retailers', 'ba-ret'), { retailerName: 'R', assignedSalesmanId: 'S001', branchId: 'B1' });
        const row = ['retailer_scoresheets:view', 'retailer_scoresheets:edit'];
        await setDoc(doc(db, 'system_access_config', 'permission_matrix'), {
          roles: { supervisor: row, branch_manager: row }, revision: 1,
        });
      },
    },
  );
  return rows;
}

function rowDocId(row, key, n) {
  return row.own ? AUDIT_ACTORS[key].uid : (row.id || `ba-doc-${n}`);
}

async function resetRowState(db, row, key, n) {
  const id = rowDocId(row, key, n);
  if (row.seed) await row.seed(db);
  if (row.stored) await setDoc(doc(db, row.col, id), row.stored);
  else await deleteDoc(doc(db, row.col, id));
  await deleteDoc(doc(db, row.col, `${id}-new`));
  if (row.run) await deleteDoc(doc(db, 'order_audit_logs', id));
}

function attemptRow(db, row, key, n) {
  const a = AUDIT_ACTORS[key];
  const id = rowDocId(row, key, n);
  if (row.run) return row.run(db, a, id);
  if (row.op === 'read') return getDoc(doc(db, row.col, id));
  if (row.op === 'create') return setDoc(doc(db, row.col, row.own ? id : `${id}-new`), row.fresh(a));
  if (row.op === 'update') return updateDoc(doc(db, row.col, id), row.patch);
  return deleteDoc(doc(db, row.col, id));
}

const PAD_UNIT = "request.auth.uid != 'zz'";

function padTree(n) {
  if (n === 1) return `(${PAD_UNIT})`;
  const h = n >> 1;
  return `(${padTree(h)} && ${padTree(n - h)})`;
}

function padRules(rules, units) {
  if (!units) return rules;
  let padded = 0;
  const out = rules.replace(
    /(allow\s+[a-z, ]+:\s*if\s+)([\s\S]*?);/g,
    (whole, head, expr) => {
      if (expr.trim() === 'false') return whole;
      padded += 1;
      return `${head}${padTree(units)} && (${expr});`;
    },
  );
  if (padded < 100) throw new Error(`padRules matched only ${padded} statements`);
  return out;
}

module.exports = {
  ACTOR_KEYS,
  AUDIT_ACTORS,
  BUDGET,
  SHAPES,
  attemptRow,
  buildAuditRows,
  expectedAllowed,
  padRules,
  padTree,
  resetRowState,
  seedAuditActors,
  v2Access,
};
