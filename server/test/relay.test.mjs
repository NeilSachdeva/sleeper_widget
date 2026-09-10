import { test } from 'node:test';
import assert from 'node:assert/strict';
import { easternDate } from '../lib/gameWindow.mjs';
import { toContentState, buildSnapshot } from '../lib/matchup.mjs';
import { HEARTBEAT_MS, START_COOLDOWN_MS, contentStateHash, currentWeek, tick } from '../lib/relay.mjs';
import { LEAGUE_ID, byeMatchups, fakeApns, fakeSleeper, fakeStore, league, matchups, rosters, silentLog, users, withScores } from './fixtures.mjs';

const sundayAfternoon = easternDate(2026, 9, 20, 16); // in the Sunday window
const mondayMorning = easternDate(2026, 9, 21, 10); // between windows, week still live
const tuesdayNoon = easternDate(2026, 9, 22, 12); // week over → final
const wednesday = easternDate(2026, 9, 23, 12);

const PUSH_TO_START = 'aa'.repeat(32);
const ACTIVITY_TOKEN = 'bb'.repeat(64);

function registration(overrides = {}) {
  return { installId: 'install-1', userId: 'u1', leagueId: LEAGUE_ID, environment: 'development', ...overrides };
}

/** Hash of what the relay would compute for these matchups at `now`. */
function hashFor(now, weekMatchups = matchups) {
  const snapshot = buildSnapshot({ userId: 'u1', league, week: 2, rosters, users, matchups: weekMatchups, now });
  return contentStateHash(toContentState(snapshot));
}

function iso(date, offsetMs = 0) {
  return new Date(date.getTime() + offsetMs).toISOString();
}

async function run({ rows, now, sleeper = fakeSleeper(), apns = fakeApns() }) {
  const store = fakeStore(rows);
  const summary = await tick({ store, sleeper, apns, now, log: silentLog });
  return { store, apns, summary };
}

test('start is pushed inside a game window', async () => {
  const { store, apns, summary } = await run({ rows: [registration({ pushToStartToken: PUSH_TO_START })], now: sundayAfternoon });
  assert.equal(summary.pushes, 1);
  assert.equal(apns.sent.length, 1);
  const push = apns.sent[0];
  assert.equal(push.token, PUSH_TO_START);
  assert.equal(push.environment, 'development');
  assert.equal(push.priority, 10);
  assert.equal(push.expiration, Math.floor(sundayAfternoon.getTime() / 1000) + 30 * 60);
  assert.equal(push.payload.aps.event, 'start');
  assert.equal(push.payload.aps['attributes-type'], 'MatchupActivityAttributes');
  assert.equal(push.payload.aps.attributes.myTeamName, 'Gridiron Gurus');
  assert.equal(push.payload.aps.attributes.opponentTeamName, 'sam');
  assert.equal(push.payload.aps['content-state'].phase, 'live');
  assert.equal(push.payload.aps['relevance-score'], 100, 'inside a window');

  const row = store.get('install-1');
  assert.equal(row.lastStartPushAt, iso(sundayAfternoon));
  assert.equal(row.lastStartKey, `${LEAGUE_ID}:2`);
  assert.equal(row.lastPhase, 'live');
  assert.equal(row.lastMargin.toFixed(2), '13.32');
});

test('start is not pushed on a bye week or outside a window', async () => {
  const bye = await run({ rows: [registration({ pushToStartToken: PUSH_TO_START })], now: sundayAfternoon, sleeper: fakeSleeper({ matchups: byeMatchups }) });
  assert.equal(bye.apns.sent.length, 0);

  const midweek = await run({ rows: [registration({ pushToStartToken: PUSH_TO_START })], now: wednesday });
  assert.equal(midweek.apns.sent.length, 0);

  const noToken = await run({ rows: [registration()], now: sundayAfternoon });
  assert.equal(noToken.apns.sent.length, 0);
});

test('start respects the 30 minute cooldown per league and week', async () => {
  const recent = await run({
    rows: [registration({ pushToStartToken: PUSH_TO_START, lastStartPushAt: iso(sundayAfternoon, -10 * 60 * 1000), lastStartKey: `${LEAGUE_ID}:2` })],
    now: sundayAfternoon,
  });
  assert.equal(recent.apns.sent.length, 0, 'sent 10 minutes ago');

  const stale = await run({
    rows: [registration({ pushToStartToken: PUSH_TO_START, lastStartPushAt: iso(sundayAfternoon, -START_COOLDOWN_MS), lastStartKey: `${LEAGUE_ID}:2` })],
    now: sundayAfternoon,
  });
  assert.equal(stale.apns.sent.length, 1, 'cooldown elapsed');

  const otherWeek = await run({
    rows: [registration({ pushToStartToken: PUSH_TO_START, lastStartPushAt: iso(sundayAfternoon, -60 * 1000), lastStartKey: `${LEAGUE_ID}:1` })],
    now: sundayAfternoon,
  });
  assert.equal(otherWeek.apns.sent.length, 1, 'last start was for a different week');
});

test('a dead push-to-start token is cleared', async () => {
  const { store, apns } = await run({
    rows: [registration({ pushToStartToken: PUSH_TO_START })],
    now: sundayAfternoon,
    apns: fakeApns([{ status: 410, reason: 'Unregistered', tokenDead: true }]),
  });
  assert.equal(apns.sent.length, 1);
  assert.equal(store.get('install-1').pushToStartToken, null);
  assert.equal(store.get('install-1').lastStartPushAt, null, 'failed start does not start the cooldown');
});

test('update is pushed when the content-state changed, then nothing until it changes again', async () => {
  const previousHash = hashFor(sundayAfternoon, withScores(80, 74.1));
  const { store, apns } = await run({
    rows: [registration({ activityToken: ACTIVITY_TOKEN, activityId: 'act-1', lastContentStateHash: previousHash, lastPushAt: iso(sundayAfternoon, -60 * 1000), lastMargin: 5.9 })],
    now: sundayAfternoon,
  });
  assert.equal(apns.sent.length, 1);
  const push = apns.sent[0];
  assert.equal(push.token, ACTIVITY_TOKEN);
  assert.equal(push.priority, 10);
  assert.equal(push.payload.aps.event, 'update');
  assert.equal(push.payload.aps['content-state'].myPoints, 87.42);
  assert.equal(push.payload.aps['relevance-score'], 100, 'inside a window');
  assert.equal('alert' in push.payload.aps, false, 'still leading → no alert');

  const row = store.get('install-1');
  assert.equal(row.lastContentStateHash, hashFor(sundayAfternoon));
  assert.equal(row.lastPushAt, iso(sundayAfternoon));

  // Same scores one minute later: no change, heartbeat not due.
  const later = new Date(sundayAfternoon.getTime() + 60 * 1000);
  const again = await run({ rows: [row], now: later });
  assert.equal(again.apns.sent.length, 0);
});

test('update carries an alert when the lead changes hands', async () => {
  const { apns } = await run({
    rows: [registration({ activityToken: ACTIVITY_TOKEN, lastContentStateHash: 'old', lastPushAt: iso(sundayAfternoon), lastMargin: -3 })],
    now: sundayAfternoon,
  });
  assert.deepEqual(apns.sent[0].payload.aps.alert, { title: 'You took the lead', body: 'Gridiron Gurus 87.42 - 74.1 sam' });
});

test('heartbeat every 20 minutes inside a window, at low priority', async () => {
  const hash = hashFor(sundayAfternoon);
  const due = await run({
    rows: [registration({ activityToken: ACTIVITY_TOKEN, lastContentStateHash: hash, lastPushAt: iso(sundayAfternoon, -HEARTBEAT_MS) })],
    now: sundayAfternoon,
  });
  assert.equal(due.apns.sent.length, 1);
  assert.equal(due.apns.sent[0].priority, 5);
  assert.equal(due.apns.sent[0].payload.aps.event, 'update');
  assert.equal(due.store.get('install-1').lastPushAt, iso(sundayAfternoon));

  const notDue = await run({
    rows: [registration({ activityToken: ACTIVITY_TOKEN, lastContentStateHash: hash, lastPushAt: iso(sundayAfternoon, -HEARTBEAT_MS + 60 * 1000) })],
    now: sundayAfternoon,
  });
  assert.equal(notDue.apns.sent.length, 0);

  // Between the Sunday and Monday windows an automatic activity is ended (one activity
  // per window keeps well inside Apple's 8-hour limit); Monday night starts a fresh one.
  const mondayHash = hashFor(mondayMorning);
  const betweenWindows = await run({
    rows: [registration({ activityToken: ACTIVITY_TOKEN, activityId: 'act-1', lastContentStateHash: mondayHash, lastPushAt: iso(mondayMorning, -2 * HEARTBEAT_MS) })],
    now: mondayMorning,
  });
  assert.equal(betweenWindows.apns.sent.length, 1);
  assert.equal(betweenWindows.apns.sent[0].payload.aps.event, 'end');
  assert.equal(betweenWindows.apns.sent[0].payload.aps['content-state'].phase, 'live');
  assert.equal(betweenWindows.store.get('install-1').activityToken, null);
  assert.equal(betweenWindows.store.get('install-1').activityId, null);
});

test('end is pushed once the week is final and the activity token is cleared', async () => {
  const { store, apns } = await run({
    rows: [registration({ activityToken: ACTIVITY_TOKEN, activityId: 'act-1', lastContentStateHash: 'x', lastPushAt: iso(tuesdayNoon) })],
    now: tuesdayNoon,
  });
  assert.equal(apns.sent.length, 1);
  const push = apns.sent[0];
  assert.equal(push.priority, 10);
  assert.equal(push.payload.aps.event, 'end');
  assert.equal(push.payload.aps['content-state'].phase, 'final');
  assert.equal(push.payload.aps['dismissal-date'], Math.floor(tuesdayNoon.getTime() / 1000) + 30 * 60);

  const row = store.get('install-1');
  assert.equal(row.activityToken, null);
  assert.equal(row.activityId, null);
  assert.equal(row.lastContentStateHash, null);
  assert.equal(row.lastPhase, 'final');
});

test('end is pushed outside a window when the matchup is not live (0-0 on Wednesday)', async () => {
  const { store, apns } = await run({
    rows: [registration({ activityToken: ACTIVITY_TOKEN })],
    now: wednesday,
    sleeper: fakeSleeper({ matchups: withScores(0, 0) }),
  });
  assert.equal(apns.sent[0].payload.aps.event, 'end');
  assert.equal(apns.sent[0].payload.aps['content-state'].phase, 'pregame');
  assert.equal(store.get('install-1').activityToken, null);
});

test('a manually started activity is not ended outside a window; it gets heartbeats instead', async () => {
  const hash = hashFor(wednesday, withScores(0, 0));
  const manual = registration({ activityToken: ACTIVITY_TOKEN, activityId: 'act-1', startedManually: true, lastContentStateHash: hash });
  const sleeper = () => fakeSleeper({ matchups: withScores(0, 0) });

  // Wednesday, 0-0 (pregame), heartbeat due → low-priority update with the out-of-window relevance score.
  const due = await run({ rows: [{ ...manual, lastPushAt: iso(wednesday, -HEARTBEAT_MS) }], now: wednesday, sleeper: sleeper() });
  assert.equal(due.apns.sent.length, 1);
  assert.equal(due.apns.sent[0].payload.aps.event, 'update');
  assert.equal(due.apns.sent[0].priority, 5);
  assert.equal(due.apns.sent[0].payload.aps['relevance-score'], 50, 'outside a window');
  assert.equal(due.apns.sent[0].payload.aps['content-state'].phase, 'pregame');
  assert.equal(due.store.get('install-1').activityToken, ACTIVITY_TOKEN, 'still running');
  assert.equal(due.store.get('install-1').lastPushAt, iso(wednesday));

  // Same, but the last heartbeat was recent → nothing.
  const notDue = await run({ rows: [{ ...manual, lastPushAt: iso(wednesday, -HEARTBEAT_MS + 60 * 1000) }], now: wednesday, sleeper: sleeper() });
  assert.equal(notDue.apns.sent.length, 0);
  assert.equal(notDue.store.get('install-1').activityToken, ACTIVITY_TOKEN);

  // Between Sunday and Monday windows a manual activity is kept alive too.
  const mondayHash = hashFor(mondayMorning);
  const betweenWindows = await run({
    rows: [registration({ activityToken: ACTIVITY_TOKEN, startedManually: true, lastContentStateHash: mondayHash, lastPushAt: iso(mondayMorning, -HEARTBEAT_MS) })],
    now: mondayMorning,
  });
  assert.equal(betweenWindows.apns.sent.length, 1);
  assert.equal(betweenWindows.apns.sent[0].payload.aps.event, 'update');
  assert.equal(betweenWindows.apns.sent[0].payload.aps['relevance-score'], 50);

  // The automatic equivalent of the Wednesday case is ended (the existing rule).
  const automatic = await run({ rows: [{ ...manual, startedManually: false, lastPushAt: iso(wednesday, -HEARTBEAT_MS) }], now: wednesday, sleeper: sleeper() });
  assert.equal(automatic.apns.sent[0].payload.aps.event, 'end');
  assert.equal(automatic.store.get('install-1').activityToken, null);
});

test('a manually started activity is still ended once the matchup is final', async () => {
  const { store, apns } = await run({
    rows: [registration({ activityToken: ACTIVITY_TOKEN, activityId: 'act-1', startedManually: true, lastContentStateHash: 'x', lastPushAt: iso(tuesdayNoon) })],
    now: tuesdayNoon,
  });
  assert.equal(apns.sent.length, 1);
  assert.equal(apns.sent[0].payload.aps.event, 'end');
  assert.equal(apns.sent[0].payload.aps['content-state'].phase, 'final');
  assert.equal(store.get('install-1').activityToken, null);
  assert.equal(store.get('install-1').activityId, null);
});

test('a dead activity token is cleared on update and on end', async () => {
  const onUpdate = await run({
    rows: [registration({ activityToken: ACTIVITY_TOKEN, activityId: 'act-1', pushToStartToken: PUSH_TO_START })],
    now: sundayAfternoon,
    apns: fakeApns([{ status: 400, reason: 'BadDeviceToken', tokenDead: true }]),
  });
  assert.equal(onUpdate.apns.sent.length, 1, 'only one push per registration per tick');
  assert.equal(onUpdate.store.get('install-1').activityToken, null);
  assert.equal(onUpdate.store.get('install-1').activityId, null);
  assert.equal(onUpdate.store.get('install-1').pushToStartToken, PUSH_TO_START, 'other token untouched');

  const onEnd = await run({
    rows: [registration({ activityToken: ACTIVITY_TOKEN })],
    now: tuesdayNoon,
    apns: fakeApns([{ status: 410, reason: 'Unregistered', tokenDead: true }]),
  });
  assert.equal(onEnd.store.get('install-1').activityToken, null);
});

test('a transient APNs failure keeps the registration unchanged for the next tick', async () => {
  const { store, apns } = await run({
    rows: [registration({ activityToken: ACTIVITY_TOKEN, lastContentStateHash: 'old' })],
    now: sundayAfternoon,
    apns: fakeApns([{ status: 503, reason: 'ServiceUnavailable' }]),
  });
  assert.equal(apns.sent.length, 1);
  assert.equal(store.get('install-1').lastContentStateHash, 'old');
  assert.equal(store.get('install-1').activityToken, ACTIVITY_TOKEN);
});

test('league data is fetched once per tick for many registrations, and errors are isolated', async () => {
  const sleeper = fakeSleeper();
  const rows = [
    registration({ installId: 'a', userId: 'u1', pushToStartToken: PUSH_TO_START }),
    registration({ installId: 'b', userId: 'u2', pushToStartToken: PUSH_TO_START }),
    registration({ installId: 'c', userId: 'nobody', pushToStartToken: PUSH_TO_START }),
  ];
  const { apns, summary } = await run({ rows, now: sundayAfternoon, sleeper });
  assert.equal(summary.registrations, 3);
  assert.equal(summary.pushes, 2);
  assert.equal(summary.errors, 1, 'user without a roster');
  assert.equal(apns.sent.length, 2);
  assert.deepEqual(sleeper.calls.sort(), ['league', 'matchups', 'rosters', 'state', 'users']);
});

test('currentWeek mirrors SleeperState.currentWeek: display_week wins, floor of 1', () => {
  assert.equal(currentWeek({ week: 2, display_week: 3 }), 3);
  assert.equal(currentWeek({ week: 2, display_week: null }), 2);
  assert.equal(currentWeek({ week: 2 }), 2);
  assert.equal(currentWeek({ week: 0, display_week: null }), 1, 'offseason');
  assert.equal(currentWeek({ week: 5, display_week: 0 }), 1, 'display_week is used even when it is lower');
  assert.equal(currentWeek({}), 1);
});

test('the week comes from display_week when it differs from week', async () => {
  const sleeper = fakeSleeper({ state: { week: 2, display_week: 3, season: '2026', season_type: 'regular' } });
  const { store, apns } = await run({ rows: [registration({ pushToStartToken: PUSH_TO_START })], now: sundayAfternoon, sleeper });
  assert.deepEqual(sleeper.weeksRequested, [3], 'matchups fetched for the displayed week');
  assert.equal(apns.sent[0].payload.aps.attributes.week, 3);
  assert.equal(store.get('install-1').lastStartKey, `${LEAGUE_ID}:3`);

  const fallback = fakeSleeper({ state: { week: 2, display_week: null, season: '2026', season_type: 'regular' } });
  await run({ rows: [registration({ pushToStartToken: PUSH_TO_START })], now: sundayAfternoon, sleeper: fallback });
  assert.deepEqual(fallback.weeksRequested, [2], 'null display_week falls back to week');
});

test('no registrations means no Sleeper calls', async () => {
  const sleeper = fakeSleeper();
  const { summary } = await run({ rows: [], now: sundayAfternoon, sleeper });
  assert.deepEqual(summary, { registrations: 0, pushes: 0, errors: 0 });
  assert.equal(sleeper.calls.length, 0);
});

test('contentStateHash ignores updatedAtUnix', () => {
  const a = { myPoints: 1, opponentPoints: 2, phase: 'live', updatedAtUnix: 1 };
  const b = { ...a, updatedAtUnix: 2 };
  assert.equal(contentStateHash(a), contentStateHash(b));
  assert.notEqual(contentStateHash(a), contentStateHash({ ...a, myPoints: 1.1 }));
  assert.notEqual(contentStateHash(a), contentStateHash({ ...a, myRecord: '1-0' }));
});

test('start is held back while the app reports suppressAutoStartUntil in the future', async () => {
  const suppressed = await run({
    rows: [registration({ pushToStartToken: PUSH_TO_START, suppressAutoStartUntil: iso(sundayAfternoon, 60 * 60 * 1000) })],
    now: sundayAfternoon,
  });
  assert.equal(suppressed.apns.sent.length, 0, 'user tapped Stop for this window');

  const expired = await run({
    rows: [registration({ pushToStartToken: PUSH_TO_START, suppressAutoStartUntil: iso(sundayAfternoon, -60 * 1000) })],
    now: sundayAfternoon,
  });
  assert.equal(expired.apns.sent.length, 1);
  assert.equal(expired.apns.sent[0].payload.aps.event, 'start');
});
