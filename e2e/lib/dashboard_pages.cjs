'use strict';

const CONTENT_LEFT = 236;
const CONTENT_TOP = 62;
const HEADING_BOTTOM = 220;

async function contentNodes(page) {
  return page.evaluate(({ left, top }) => Array.from(document.querySelectorAll('flt-semantics'))
    .map((n) => {
      const r = n.getBoundingClientRect();
      const text = (n.getAttribute('aria-label') || n.textContent || '').trim();
      return { text, role: n.getAttribute('role') || '', x: r.left, y: r.top, w: r.width, h: r.height, labelled: n.hasAttribute('aria-label') };
    })
    .filter((n) => n.text && n.w > 0 && n.h > 0 && n.y >= top - 70 && (n.x >= left || (n.labelled && n.w >= 1000))), { left: CONTENT_LEFT, top: CONTENT_TOP });
}

const firstLine = (text) => text.split(/\r?\n/)[0].trim();

function headingFound(nodes, title) {
  return nodes.some((n) => n.role !== 'button' && n.y < HEADING_BOTTOM && firstLine(n.text) === title);
}

function markerFound(nodes, marker) {
  const test = marker instanceof RegExp ? (text) => marker.test(text) : (text) => text.includes(marker);
  return nodes.some((n) => test(n.text));
}

async function expectContent(page, { title, marker, timeout = 15000 }) {
  const deadline = Date.now() + timeout;
  let nodes = [];
  let headingOk = false;
  let markerOk = !marker;
  while (Date.now() < deadline) {
    nodes = await contentNodes(page);
    headingOk = headingFound(nodes, title);
    markerOk = !marker || markerFound(nodes, marker);
    if (headingOk && markerOk) return nodes;
    await page.waitForTimeout(250);
  }
  const shown = nodes.filter((n) => n.y < HEADING_BOTTOM).map((n) => firstLine(n.text)).slice(0, 8);
  const problems = [];
  if (!headingOk) problems.push(`content-area heading "${title}" is not shown (top of the content area shows: ${JSON.stringify(shown)})`);
  if (!markerOk) problems.push(`page marker ${marker} is not in the content area`);
  throw new Error(problems.join('; '));
}

async function paintedHighlightBands(page, railWidth = 240) {
  const size = page.viewportSize();
  const png = await page.screenshot({ clip: { x: 0, y: 60, width: railWidth, height: size.height - 60 } });
  return page.evaluate(async ({ b64 }) => {
    const img = new Image();
    await new Promise((resolve, reject) => { img.onload = resolve; img.onerror = reject; img.src = `data:image/png;base64,${b64}`; });
    const canvas = document.createElement('canvas');
    canvas.width = img.width;
    canvas.height = img.height;
    const ctx = canvas.getContext('2d');
    ctx.drawImage(img, 0, 0);
    const pad = ctx.getImageData(3, 0, 1, img.height).data;
    const row = ctx.getImageData(16, 0, 1, img.height).data;
    const differs = (y) => Math.abs(pad[y * 4] - row[y * 4]) + Math.abs(pad[y * 4 + 1] - row[y * 4 + 1]) + Math.abs(pad[y * 4 + 2] - row[y * 4 + 2]) > 8;
    const bands = [];
    let start = -1;
    for (let y = 0; y <= img.height; y += 1) {
      const on = y < img.height && differs(y);
      if (on && start < 0) start = y;
      if (!on && start >= 0) {
        if (y - start > 20) bands.push({ top: start + 60, bottom: y - 1 + 60 });
        start = -1;
      }
    }
    return bands;
  }, { b64: png.toString('base64') });
}

async function railEntryRect(page, label) {
  return page.evaluate((text) => {
    const node = Array.from(document.querySelectorAll('flt-semantics[role="button"]')).find((n) => {
      const r = n.getBoundingClientRect();
      return r.left < 250 && (n.getAttribute('aria-label') || n.textContent || '').trim().split(/\r?\n/)[0].replace(/, current page$/, '') === text;
    });
    if (!node) return null;
    const r = node.getBoundingClientRect();
    return { top: r.top, bottom: r.bottom };
  }, label);
}

async function scrollRailWithWheel(page, amount) {
  const size = page.viewportSize();
  await page.mouse.move(100, size.height / 2);
  await page.mouse.wheel(0, -10000);
  await page.waitForTimeout(400);
  await page.mouse.wheel(0, amount);
  await page.waitForTimeout(1000);
}

async function clickRailEntryWithMouse(page, label) {
  const rect = await railEntryRect(page, label);
  if (!rect) throw new Error(`rail entry "${label}" has no semantics node`);
  const size = page.viewportSize();
  if (rect.top < 64 || rect.bottom > size.height - 4) throw new Error(`rail entry "${label}" is not inside the visible rail (${Math.round(rect.top)}-${Math.round(rect.bottom)})`);
  await page.mouse.click(120, (rect.top + rect.bottom) / 2);
  await page.waitForTimeout(1500);
}

async function expectRailPaintMatchesSemantics(page, label) {
  await page.mouse.move(page.viewportSize().width / 2, page.viewportSize().height / 2);
  await page.waitForTimeout(300);
  const rect = await railEntryRect(page, label);
  if (!rect) throw new Error(`rail entry "${label}" has no semantics node`);
  const bands = await paintedHighlightBands(page);
  const middle = (rect.top + rect.bottom) / 2;
  if (!bands.some((b) => middle >= b.top && middle <= b.bottom)) {
    throw new Error(`the painted highlighted row is at ${JSON.stringify(bands)} but the semantics node of "${label}" sits at ${Math.round(rect.top)}-${Math.round(rect.bottom)}: a mouse click lands on the wrong rail entry`);
  }
}

module.exports = { scrollRailWithWheel, clickRailEntryWithMouse, paintedHighlightBands, railEntryRect, expectRailPaintMatchesSemantics, contentNodes, expectContent, headingFound, markerFound, firstLine, CONTENT_LEFT };
