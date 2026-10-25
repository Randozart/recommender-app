//===----------------------------------------------------------------------===//
// SPDX-License-Identifier: Apache-2.0 WITH LLVM-exception
//===----------------------------------------------------------------------===//
// Real generated-app/server gate for I11. A dedicated PostgreSQL transaction
// holds the test account row until the browser has painted the new result.
import assert from 'node:assert/strict';
import { createRequire } from 'node:module';
import { createServer } from 'node:http';
import { execFileSync, spawn } from 'node:child_process';
import { readFile } from 'node:fs/promises';
import { extname, relative as relativePath, resolve, sep } from 'node:path';
import { randomBytes } from 'node:crypto';

const require = createRequire(import.meta.url);
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const webRoot = resolve(process.argv[2]);
const api = process.argv[3] || 'http://127.0.0.1:18110';
const psql = process.env.PSQL || 'psql';
const psqlPrefix = process.env.PSQL_ARGS ? JSON.parse(process.env.PSQL_ARGS) : [];
const mime = { '.css': 'text/css', '.html': 'text/html', '.js': 'text/javascript', '.mjs': 'text/javascript', '.wasm': 'application/wasm' };
const staticServer = createServer(async (request, response) => {
  const name = decodeURIComponent(new URL(request.url, 'http://localhost').pathname).replace(/^\/+/, '') || 'app.html';
  if (name === 'favicon.ico') { response.writeHead(204).end(); return; }
  const path = resolve(webRoot, name);
  const outside = relativePath(webRoot, path);
  if (outside === '..' || outside.startsWith(`..${sep}`)) { response.writeHead(404).end(); return; }
  try {
    const body = await readFile(path);
    response.writeHead(200, { 'content-type': mime[extname(path)] || 'application/octet-stream' });
    response.end(body);
  } catch { response.writeHead(404).end(); }
});
await new Promise(resolve => staticServer.listen(0, '127.0.0.1', resolve));
const staticPort = staticServer.address().port;
let browser;
let page;
const username = `i11_${randomBytes(8).toString('hex')}`;
const password = `I11-${randomBytes(12).toString('hex')}`;
const pgEnv = { ...process.env, PGHOST: process.env.PGHOST || '127.0.0.1', PGPORT: process.env.PGPORT || '5432' };
let lockProcess;

function psqlQuery(sql) {
  return execFileSync(psql, [...psqlPrefix, '-X', '-v', 'ON_ERROR_STOP=1', '-At', '-c', sql],
    { env: pgEnv, encoding: 'utf8', stdio: ['ignore', 'pipe', 'pipe'] }).trim();
}

function waitForMarker(child, marker, timeoutMs = 10000) {
  return new Promise((resolve, reject) => {
    let output = '';
    const timer = setTimeout(() => reject(new Error(`psql did not report ${marker}: ${output}`)), timeoutMs);
    const collect = chunk => {
      output += chunk.toString();
      if (output.includes(marker)) { clearTimeout(timer); resolve(); }
    };
    child.stdout.on('data', collect);
    child.stderr.on('data', collect);
    child.once('exit', code => {
      if (!output.includes(marker)) { clearTimeout(timer); reject(new Error(`psql exited ${code}: ${output}`)); }
    });
  });
}

const pageErrors = [];
const requestLog = [];
try {
  browser = await chromium.launch({ channel: process.env.PLAYWRIGHT_CHANNEL || 'msedge', headless: true });
  page = await browser.newPage();
  page.setDefaultTimeout(15000);
  page.on('pageerror', error => pageErrors.push(error.message));
  page.on('console', message => { if (message.type() === 'error') pageErrors.push(message.text()); });
  page.on('request', request => requestLog.push({ url: request.url(), method: request.method(), resource: request.resourceType() }));
  await page.addInitScript(() => {
    window.__i11 = { incoming: [], sent: [], xhrSends: 0, frames: 0, maxLongTask: 0,
      longTaskWindow: 0, recommendationMutations: 0, recommendationChanges: [] };
    const NativeSocket = window.WebSocket;
    window.WebSocket = class extends NativeSocket {
      constructor(...args) {
        super(...args);
        this.addEventListener('message', event => {
          try {
            const value = JSON.parse(event.data);
            window.__i11.incoming.push(value);
          } catch { }
        });
      }
      send(value) {
        try { window.__i11.sent.push(JSON.parse(value)); } catch { }
        return super.send(value);
      }
    };
    const nativeSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.send = function (...args) {
      window.__i11.xhrSends += 1;
      return nativeSend.apply(this, args);
    };
    const frame = () => { window.__i11.frames += 1; requestAnimationFrame(frame); };
    requestAnimationFrame(frame);
    try {
      new PerformanceObserver(entries => {
        for (const entry of entries.getEntries()) {
          if (entry.startTime >= window.__i11.longTaskWindow)
            window.__i11.maxLongTask = Math.max(window.__i11.maxLongTask, entry.duration);
        }
      }).observe({ type: 'longtask', buffered: true });
    } catch { }
    const observeRecommendations = () => {
      const target = document.querySelector('#recommendations');
      if (!target || target.__i11Observed) return;
      target.__i11Observed = true;
      new MutationObserver(records => {
        window.__i11.recommendationMutations += records.length;
        for (const record of records) window.__i11.recommendationChanges.push({
          type: record.type, target: record.target.nodeName, added: record.addedNodes.length,
          removed: record.removedNodes.length, text: record.target.textContent?.slice(0, 120),
        });
      })
        .observe(target, { childList: true, subtree: true, characterData: true });
    };
    new MutationObserver(observeRecommendations).observe(document, { childList: true, subtree: true });
  });

  await page.goto(`http://127.0.0.1:${staticPort}/app.html?api=${encodeURIComponent(api)}`);
  await page.locator('#username').fill(username);
  await page.locator('#password').fill(password);
  await page.locator('#register').click();
  await page.getByText('Account created. Sign in with these credentials.', { exact: true }).waitFor({ timeout: 15000 });

  const accountId = Number(psqlQuery(`SELECT id FROM accounts WHERE username='${username}'`));
  assert.ok(Number.isInteger(accountId) && accountId > 0, 'registered account must exist in the configured test database');
  const stamp = Date.now();
  psqlQuery(`INSERT INTO ratings(account_id,item_id,rating,ts) VALUES ` +
    [0, 1, 2, 3, 4].map(item => `(${accountId},${item},3,${stamp + item})`).join(',') +
    ` ON CONFLICT(account_id,item_id) DO UPDATE SET rating=EXCLUDED.rating,ts=EXCLUDED.ts`);

  await page.locator('#login').click();
  await page.getByText('Live', { exact: true }).waitFor({ timeout: 20000 });
  await page.waitForFunction(() => document.querySelectorAll('#ratings').length === 1 &&
    document.querySelector('.rated-films .count')?.textContent.trim() === '5', null, { timeout: 15000 });
  const catalogue = await fetch(`${api}/movies`).then(response => response.json());
  const movieTitle = catalogue.movies.find(movie => movie.item_id === 0).title;
  const initialRevision = await page.evaluate(() => document.querySelector('#ratings').textContent);

  lockProcess = spawn(psql, [...psqlPrefix, '-X', '-q', '-v', 'ON_ERROR_STOP=1', '-d', process.env.PGDATABASE],
    { env: pgEnv, stdio: ['pipe', 'pipe', 'pipe'] });
  lockProcess.stdin.write(`BEGIN;\nSELECT id FROM accounts WHERE id=${accountId} FOR UPDATE;\n\\echo I11_LOCK_READY\n`);
  await waitForMarker(lockProcess, 'I11_LOCK_READY');

  const beforeClickRequests = requestLog.length;
  const beforeClickFrameCount = await page.evaluate(() => window.__i11.frames);
  await page.evaluate(() => {
    window.__i11.maxLongTask = 0;
    window.__i11.longTaskWindow = performance.now();
  });
  const beforeClickRecommendationCount = await page.evaluate(() => window.__i11.incoming
    .filter(event => event.type === 'recommendations').length);
  await page.locator('.movie-list li').filter({ has: page.getByText(movieTitle, { exact: true }) }).getByRole('button').click();
  await page.getByRole('button', { name: '1 star', exact: true }).click();
  await page.locator('#save-rating').click();
  await page.waitForFunction(title => document.querySelector('#ratings')?.textContent.includes(`${title} — 1 / 5 · saving`), movieTitle,
    { timeout: 5000 });
  await page.waitForFunction(() => window.__i11.sent.length === 1, null, { timeout: 10000 });
  const command = await page.evaluate(() => window.__i11.sent[0]);
  assert.equal(command.item_id, 0);
  assert.equal(command.rating, 1);
  const operationRevision = await page.evaluate(() => {
    const text = document.querySelector('#ratings').textContent;
    return text;
  });
  assert.notEqual(operationRevision, initialRevision, 'optimistic edit must paint while persistence is blocked');
  await page.getByText(/accepted; waiting for the save confirmation/i).waitFor({ timeout: 10000 });

  await page.waitForFunction(operationId => window.__i11.incoming.some(event =>
    event.type === 'accepted' && event.operation_id === operationId), command.operation_id, { timeout: 15000 });
  const accepted = await page.evaluate(operationId => window.__i11.incoming.find(event =>
    event.type === 'accepted' && event.operation_id === operationId), command.operation_id);
  await page.waitForFunction(({ revision, count }) => window.__i11.incoming.some(event =>
    event.type === 'recommendations' && event.revision === revision) &&
    window.__i11.incoming.filter(event => event.type === 'recommendations').length > count,
    { revision: accepted.revision, count: beforeClickRecommendationCount }, { timeout: 30000 });
  const result = await page.evaluate(revision => window.__i11.incoming.find(event =>
    event.type === 'recommendations' && event.revision === revision), accepted.revision);
  assert.ok(result, 'fresh recommendations must arrive before the row lock is released');
  assert.equal(await page.evaluate(() => window.__i11.incoming.filter(event => event.type === 'recommendations').length),
    beforeClickRecommendationCount + 1, 'one accepted profile revision should produce one recommendation event');
  assert.equal(await page.locator('#save-status').innerText(), 'Rating accepted; waiting for the save confirmation.');
  assert.equal(await page.evaluate(() => window.__i11.incoming.some(event => event.type === 'saved')), false,
    'save must remain unconfirmed while the database row is locked');
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const paintedItems = await page.locator('#recommendations li strong').allTextContents();
  assert.deepEqual(paintedItems, result.recommendations.map(item => catalogue.movies.find(movie => movie.item_id === item.item_id).title),
    'recommendation event must be reflected in the rendered list after paint opportunities');
  const mutationCountAfterResult = await page.evaluate(() => window.__i11.recommendationMutations);
  const frameCountWhileBlocked = await page.evaluate(() => window.__i11.frames);
  const postClickRequests = requestLog.slice(beforeClickRequests);
  assert.ok(frameCountWhileBlocked > beforeClickFrameCount, 'browser animation frames must continue while the database write is blocked');
  assert.equal(await page.evaluate(() => window.__i11.xhrSends), 0, 'app must not use synchronous XMLHttpRequest');
  assert.ok(await page.evaluate(() => window.__i11.maxLongTask) < 50,
    'the blocked persistence wait must not create a browser main-thread task of 50 ms or longer');
  assert.equal(postClickRequests.filter(item => item.method === 'GET' && /\/v1\/state|\/recommendations/.test(new URL(item.url).pathname)).length, 0,
    'rating flow must not issue state or recommendation GET requests');
  assert.equal(postClickRequests.filter(item => item.method === 'GET').length, 0,
    'rating flow must not perform a follow-up GET');
  assert.equal(postClickRequests.filter(item => item.method === 'POST' && new URL(item.url).pathname === '/v1/ratings').length, 0,
    'the live WebSocket command must not fall back to a duplicate HTTP submission');

  lockProcess.stdin.write('COMMIT;\n\\q\n');
  await new Promise((resolve, reject) => {
    lockProcess.once('exit', code => code === 0 ? resolve() : reject(new Error(`database lock transaction exited ${code}`)));
  });
  lockProcess = undefined;
  await page.getByText('Rating saved.', { exact: true }).waitFor({ timeout: 20000 });
  await page.evaluate(() => new Promise(resolve => setTimeout(() =>
    requestAnimationFrame(() => requestAnimationFrame(resolve)), 250)));
  const savedItems = await page.locator('#recommendations li strong').allTextContents();
  assert.deepEqual(savedItems, paintedItems, 'saved confirmation must not replace recommendations');
  const mutationsAfterSave = await page.evaluate(() => window.__i11.recommendationChanges.slice(-30));
  assert.equal(await page.evaluate(() => window.__i11.recommendationMutations), mutationCountAfterResult,
    `saved confirmation must not cause a duplicate recommendation render: ${JSON.stringify(mutationsAfterSave)}`);
  const afterClickRequests = requestLog.slice(beforeClickRequests);
  assert.equal(afterClickRequests.filter(item => item.method === 'GET').length, 0,
    'save confirmation must not trigger a follow-up GET');
  assert.equal(await page.evaluate(() => window.__i11.incoming.filter(event => event.type === 'recommendations').length),
    beforeClickRecommendationCount + 1, 'save completion must not emit another recommendation event');
  assert.equal((await page.locator('#ratings').innerText()).includes('· saving'), false,
    'saved confirmation must clear the pending label while preserving the rating');
  assert.ok((await page.locator('#ratings').innerText()).includes(`${movieTitle} — 1 / 5`),
    'saved confirmation must retain the newly accepted rating value');
  assert.deepEqual(pageErrors, [], `browser must have no console or runtime errors: ${pageErrors.join('; ')}`);
  console.log(JSON.stringify({
    gate: 'I11 real browser/server integration', username, accountId, api,
    pendingPaint: true, resultBeforeDatabaseCommit: true, savedAfterCommit: true,
    recommendationMutationCount: mutationCountAfterResult,
    recommendationRenderUnchangedAfterSave: true,
    followupGetCount: afterClickRequests.filter(item => item.method === 'GET').length,
    synchronousXhrCount: await page.evaluate(() => window.__i11.xhrSends),
    animationFramesWhileBlocked: frameCountWhileBlocked,
    maxLongTaskMs: await page.evaluate(() => window.__i11.maxLongTask),
  }));
} catch (error) {
  console.error(await page?.locator('body').innerText());
  console.error({ pageErrors, requests: requestLog });
  throw error;
} finally {
  if (lockProcess && lockProcess.exitCode === null) {
    lockProcess.stdin.write('ROLLBACK;\n\\q\n');
    await new Promise(resolve => lockProcess.once('exit', resolve)).catch(() => {});
  }
  if (browser) await browser.close();
  await new Promise(resolve => staticServer.close(resolve));
}
