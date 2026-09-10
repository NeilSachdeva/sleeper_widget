import { after, before, test } from 'node:test';
import assert from 'node:assert/strict';
import { createRelayServer, validateRegistration } from '../lib/http.mjs';
import { silentLog } from './fixtures.mjs';

/** Minimal in-memory store with the methods the HTTP layer uses. */
function memoryStore() {
  const rows = new Map();
  return {
    rows,
    size: () => rows.size,
    put: (registration) => {
      const row = { ...registration, updatedAt: 'now' };
      rows.set(registration.installId, row);
      return row;
    },
    remove: (installId) => rows.delete(installId),
  };
}

const body = {
  installId: 'INSTALL-1',
  userId: 'u1',
  leagueId: 'league-1',
  pushToStartToken: 'ab12',
  activityToken: null,
  activityId: null,
  environment: 'development',
  timeZone: 'America/New_York',
};

test('validateRegistration', () => {
  assert.deepEqual(validateRegistration(body, 'INSTALL-1'), {
    registration: {
      installId: 'INSTALL-1',
      userId: 'u1',
      leagueId: 'league-1',
      environment: 'development',
      timeZone: 'America/New_York',
      activityId: null,
      pushToStartToken: 'ab12',
      activityToken: null,
      startedManually: false,
    },
  });
  assert.equal(validateRegistration({ ...body, startedManually: true }, 'INSTALL-1').registration.startedManually, true);
  assert.equal(validateRegistration({ ...body, startedManually: false }, 'INSTALL-1').registration.startedManually, false);
  assert.equal(validateRegistration({ ...body, startedManually: null }, 'INSTALL-1').registration.startedManually, false, 'null → false');
  assert.deepEqual(validateRegistration({ ...body, startedManually: 'yes' }, 'INSTALL-1'), { error: 'startedManually must be a boolean' });
  assert.deepEqual(validateRegistration(body, 'other'), { error: 'installId in body does not match the URL' });
  assert.deepEqual(validateRegistration({ ...body, userId: '' }, 'INSTALL-1'), { error: 'userId is required' });
  assert.deepEqual(validateRegistration({ ...body, leagueId: undefined }, 'INSTALL-1'), { error: 'leagueId is required' });
  assert.deepEqual(validateRegistration({ ...body, environment: 'staging' }, 'INSTALL-1'), {
    error: 'environment must be "development" or "production"',
  });
  assert.deepEqual(validateRegistration({ ...body, activityToken: 'not hex!' }, 'INSTALL-1'), { error: 'activityToken must be a hex string' });
  assert.deepEqual(validateRegistration([], 'INSTALL-1'), { error: 'body must be a JSON object' });
  assert.equal(validateRegistration({ ...body, pushToStartToken: '' }, 'INSTALL-1').registration.pushToStartToken, null, 'empty → null');
});

const openStore = memoryStore();
const openServer = createRelayServer({ store: openStore, log: silentLog });
const privateStore = memoryStore();
const privateServer = createRelayServer({ store: privateStore, authToken: 'secret', log: silentLog });
let openUrl;
let privateUrl;

before(async () => {
  openUrl = await listen(openServer);
  privateUrl = await listen(privateServer);
});

after(() => {
  openServer.close();
  privateServer.close();
});

function listen(server) {
  return new Promise((resolve) => {
    server.listen(0, '127.0.0.1', () => resolve(`http://127.0.0.1:${server.address().port}`));
  });
}

test('PUT stores a registration and health reports it', async () => {
  const put = await fetch(`${openUrl}/v1/registrations/INSTALL-1`, {
    method: 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(body),
  });
  assert.equal(put.status, 204);
  assert.equal(openStore.rows.get('INSTALL-1').leagueId, 'league-1');
  assert.equal(openStore.rows.get('INSTALL-1').startedManually, false, 'absent in the body → false');

  const manual = await fetch(`${openUrl}/v1/registrations/INSTALL-1`, {
    method: 'PUT',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify({ ...body, startedManually: true }),
  });
  assert.equal(manual.status, 204);
  assert.equal(openStore.rows.get('INSTALL-1').startedManually, true);

  const health = await fetch(`${openUrl}/healthz`);
  assert.equal(health.status, 200);
  assert.deepEqual(await health.json(), { ok: true, registrations: 1 });

  const del = await fetch(`${openUrl}/v1/registrations/INSTALL-1`, { method: 'DELETE' });
  assert.equal(del.status, 204);
  assert.equal(openStore.size(), 0);
  const delAgain = await fetch(`${openUrl}/v1/registrations/INSTALL-1`, { method: 'DELETE' });
  assert.equal(delAgain.status, 204, 'idempotent');
});

test('bad requests', async () => {
  const mismatch = await fetch(`${openUrl}/v1/registrations/OTHER`, { method: 'PUT', body: JSON.stringify(body) });
  assert.equal(mismatch.status, 400);
  assert.match((await mismatch.json()).error, /installId/);

  const invalidJson = await fetch(`${openUrl}/v1/registrations/INSTALL-1`, { method: 'PUT', body: '{not json' });
  assert.equal(invalidJson.status, 400);

  const missingField = await fetch(`${openUrl}/v1/registrations/INSTALL-1`, {
    method: 'PUT',
    body: JSON.stringify({ ...body, environment: undefined }),
  });
  assert.equal(missingField.status, 400);
  assert.deepEqual(await missingField.json(), { error: 'environment is required' });

  const tooLarge = await fetch(`${openUrl}/v1/registrations/INSTALL-1`, {
    method: 'PUT',
    body: JSON.stringify({ ...body, timeZone: 'x'.repeat(20 * 1024) }),
  });
  assert.equal(tooLarge.status, 413);
  assert.equal(openStore.size(), 0);
});

test('unknown routes are 404', async () => {
  assert.equal((await fetch(`${openUrl}/`)).status, 404);
  assert.equal((await fetch(`${openUrl}/v1/registrations`)).status, 404);
  assert.equal((await fetch(`${openUrl}/v1/registrations/a/b`)).status, 404);
  assert.equal((await fetch(`${openUrl}/v1/registrations/a`, { method: 'POST' })).status, 404);
  assert.equal((await fetch(`${openUrl}/healthz`, { method: 'DELETE' })).status, 404);
});

test('RELAY_AUTH_TOKEN protects the registration routes but not health', async () => {
  const anonymous = await fetch(`${privateUrl}/v1/registrations/INSTALL-1`, { method: 'PUT', body: JSON.stringify(body) });
  assert.equal(anonymous.status, 401);

  const wrong = await fetch(`${privateUrl}/v1/registrations/INSTALL-1`, {
    method: 'DELETE',
    headers: { authorization: 'Bearer nope' },
  });
  assert.equal(wrong.status, 401);

  const authorized = await fetch(`${privateUrl}/v1/registrations/INSTALL-1`, {
    method: 'PUT',
    headers: { authorization: 'Bearer secret' },
    body: JSON.stringify(body),
  });
  assert.equal(authorized.status, 204);
  assert.equal(privateStore.size(), 1);

  assert.equal((await fetch(`${privateUrl}/healthz`)).status, 200);
});
