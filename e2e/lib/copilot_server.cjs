'use strict';

const http = require('node:http');

const PORT = 18765;
const ANSWERS = {
  'anything urgent for me right now': { name: 'daily_briefing', args: {} },
  'tell me more about number two': { name: 'explain_item', args: { position: 2 } },
  'park number two for later': { name: 'set_item_status', args: { position: 2, status: 'in_review' } },
  'close that one off for good': { name: 'set_item_status', args: { status: 'resolved' } },
  'dig up ahmad stuff': { name: 'search_orders', args: { salesperson: 'Ahmad' } },
  'grab kedai stuff from last week': { name: 'search_orders', args: { retailer: 'Choice Supermarket', period: 'last_week' } },
  'send that to a spreadsheet': { name: 'export_results', args: {} },
  'what did choice supermarket sell': { name: 'search_orders', args: { salesperson: 'Choice Supermarket' } },
  'somewhere to see what customers sent us':{ name: 'navigate_to_page', args: { page: 'all_orders' } },
};

function start() {
  const state = { readyAt: 0, requests: [] };
  const server = http.createServer((req, res) => {
    const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, content-type' };
    const send = (code, body) => {
      res.writeHead(code, { ...cors, 'Content-Type': 'application/json' });
      res.end(JSON.stringify(body));
    };
    if (req.method === 'OPTIONS') return send(204, {});
    if (req.method === 'GET' && req.url === '/health') {
      const ready = Date.now() >= state.readyAt;
      return send(ready ? 200 : 503, { ready });
    }
    if (req.method !== 'POST' || req.url !== '/v1/interpret') return send(404, {});
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      const auth = req.headers.authorization || '';
      if (!/^Bearer \S+$/.test(auth)) return send(401, { error: 'sign-in required' });
      const body = JSON.parse(raw);
      state.requests.push({ text: body.text, actions: body.actions, pages: body.pages.length });
      if (body.text.startsWith('spam')) return send(429, { error: 'too many requests' });
      const call = ANSWERS[body.text.toLowerCase()] || null;
      send(200, { call, confidence: call ? 0.99 : 0, latencyMs: 1 });
    });
  });
  return new Promise((resolve) => server.listen(PORT, '127.0.0.1', () => resolve({
    url: `http://127.0.0.1:${PORT}`,
    requests: state.requests,
    sleepFor(ms) { state.readyAt = Date.now() + ms; },
    isReady() { return Date.now() >= state.readyAt; },
    close: () => new Promise((r) => server.close(r)),
  })));
}

module.exports = { PORT, ANSWERS, start };
