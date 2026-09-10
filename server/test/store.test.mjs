import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { createStore } from '../lib/store.mjs';

function tempStore() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'relay-store-'));
  const filePath = path.join(dir, 'nested', 'registrations.json');
  let clock = new Date('2026-09-20T20:00:00Z');
  const store = createStore({ path: filePath, now: () => clock });
  return { store, filePath, dir, tickClock: () => (clock = new Date(clock.getTime() + 1000)) };
}

const registration = {
  installId: 'install-1',
  userId: 'u1',
  leagueId: 'league-1',
  pushToStartToken: 'aa',
  activityToken: null,
  activityId: null,
  environment: 'development',
  timeZone: 'America/New_York',
};

test('load on a missing file gives an empty store', () => {
  const { store } = tempStore();
  store.load();
  assert.equal(store.size(), 0);
  assert.deepEqual(store.all(), []);
});

test('put, get, patch, remove and reload', () => {
  const { store, filePath, dir, tickClock } = tempStore();
  store.load();

  const row = store.put(registration);
  assert.equal(row.updatedAt, '2026-09-20T20:00:00.000Z');
  assert.equal(row.lastContentStateHash, null);
  assert.equal(row.lastStartPushAt, null);
  assert.equal(row.startedManually, false, 'absent → false');
  assert.equal(store.put({ ...registration, startedManually: true }).startedManually, true);
  assert.equal(store.put({ ...registration, startedManually: 'yes' }).startedManually, false, 'only a real true counts');
  store.put(registration);
  assert.deepEqual(store.get('install-1'), row);
  assert.equal(fs.existsSync(filePath), true, 'directory is created and the file written');

  tickClock();
  store.patch('install-1', { lastPushAt: '2026-09-20T20:00:01.000Z', lastMargin: 3.5 });
  assert.equal(store.get('install-1').lastMargin, 3.5);
  assert.equal(store.get('install-1').updatedAt, '2026-09-20T20:00:01.000Z');
  assert.equal(store.patch('missing', { lastMargin: 1 }), null);

  const reloaded = createStore({ path: filePath });
  reloaded.load();
  assert.deepEqual(reloaded.get('install-1'), store.get('install-1'));

  assert.equal(store.remove('install-1'), true);
  assert.equal(store.remove('install-1'), false);
  assert.equal(store.size(), 0);
  reloaded.load();
  assert.equal(reloaded.size(), 0);

  const leftovers = fs.readdirSync(path.dirname(filePath)).filter((name) => name.endsWith('.tmp'));
  assert.deepEqual(leftovers, [], 'atomic writes leave no temp files');
  fs.rmSync(dir, { recursive: true, force: true });
});

test('put keeps bookkeeping, but resets activity bookkeeping when the activity token changes', () => {
  const { store, dir } = tempStore();
  store.load();
  store.put({ ...registration, activityToken: 'bb', activityId: 'act-1' });
  store.patch('install-1', { lastContentStateHash: 'hash', lastPushAt: 't', lastStartPushAt: 's', lastStartKey: 'k', lastMargin: 2, lastPhase: 'live' });

  const same = store.put({ ...registration, activityToken: 'bb', activityId: 'act-1', pushToStartToken: 'cc' });
  assert.equal(same.pushToStartToken, 'cc');
  assert.equal(same.lastContentStateHash, 'hash', 'same activity → keep what we sent');
  assert.equal(same.lastStartPushAt, 's');

  const changed = store.put({ ...registration, activityToken: 'dd', activityId: 'act-2' });
  assert.equal(changed.lastContentStateHash, null);
  assert.equal(changed.lastPushAt, null);
  assert.equal(changed.lastStartPushAt, 's', 'start cooldown survives');
  assert.equal(changed.lastMargin, 2, 'matchup memory survives');

  const ended = store.put({ ...registration, activityToken: null, activityId: null });
  assert.equal(ended.activityToken, null);
  assert.equal(ended.lastContentStateHash, null);
  fs.rmSync(dir, { recursive: true, force: true });
});

test('put ignores unknown fields and fills missing optional ones with null', () => {
  const { store, dir } = tempStore();
  store.load();
  const row = store.put({ installId: 'x', userId: 'u', leagueId: 'l', environment: 'production', extra: 'nope' });
  assert.equal('extra' in row, false);
  assert.equal(row.pushToStartToken, null);
  assert.equal(row.timeZone, null);
  fs.rmSync(dir, { recursive: true, force: true });
});
