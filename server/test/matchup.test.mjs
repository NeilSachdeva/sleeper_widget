import { test } from 'node:test';
import assert from 'node:assert/strict';
import { easternDate } from '../lib/gameWindow.mjs';
import { MatchupError, buildSnapshot, margin, toAttributes, toContentState } from '../lib/matchup.mjs';
import { byeMatchups, league, matchups, rosters, users, withScores } from './fixtures.mjs';

const sundayAfternoon = easternDate(2026, 9, 20, 16);
const wednesday = easternDate(2026, 9, 16, 12);

function build(overrides = {}) {
  return buildSnapshot({ userId: 'u1', league, week: 2, rosters, users, matchups, now: sundayAfternoon, ...overrides });
}

test('head-to-head matchup', () => {
  const snapshot = build();
  assert.equal(snapshot.leagueId, league.league_id);
  assert.equal(snapshot.leagueName, 'Sunday Scaries');
  assert.equal(snapshot.season, '2026');
  assert.equal(snapshot.week, 2);
  assert.deepEqual(snapshot.me, {
    rosterId: 1, name: 'Gridiron Gurus', ownerName: 'neil', avatarId: 'avatar-1', points: 87.42, record: '1-0',
  });
  assert.deepEqual(snapshot.opponent, {
    rosterId: 2, name: 'sam', ownerName: 'sam', avatarId: null, points: 74.1, record: '0-1',
  });
  assert.equal(snapshot.phase, 'live');
  assert.equal(snapshot.updatedAt, sundayAfternoon);
  assert.equal(margin(snapshot).toFixed(2), '13.32');
});

test('bye week has no opponent; its phase still follows the week', () => {
  const snapshot = build({ matchups: byeMatchups });
  assert.equal(snapshot.opponent, null);
  assert.equal(snapshot.phase, 'live', 'inside the live span');
  assert.equal(build({ matchups: byeMatchups, now: new Date('2026-09-23T16:00:00Z') }).phase, 'pregame', 'midweek with no points');
  assert.equal(snapshot.me.points, 0);
  assert.equal(margin(snapshot), 0);
});

test('custom_points override computed points', () => {
  const overridden = matchups.map((m) => (m.roster_id === 1 ? { ...m, custom_points: 100.5 } : m));
  assert.equal(build({ matchups: overridden }).me.points, 100.5);
  const missing = matchups.map((m) => (m.roster_id === 1 ? { roster_id: 1, matchup_id: 1 } : m));
  assert.equal(build({ matchups: missing }).me.points, 0, 'no points at all → 0');
});

test('team name fallbacks and records', () => {
  const pat = build({ userId: 'u3' });
  assert.equal(pat.me.name, 'pat', 'no metadata → display_name');
  assert.equal(pat.me.record, '1-1-1', 'ties are shown');
  assert.equal(pat.opponent.name, 'Team 4', 'orphan roster → Team <roster_id>');
  assert.equal(pat.opponent.record, null);
  assert.equal(pat.opponent.ownerName, null);

  const sam = build({ userId: 'u2' });
  assert.equal(sam.me.name, 'sam', 'blank team_name → display_name');
  assert.equal(sam.opponent.name, 'Gridiron Gurus');
});

test('phase follows the game window outside the live span', () => {
  assert.equal(build({ now: wednesday }).phase, 'final', 'points exist and the week is over');
  assert.equal(build({ now: wednesday, matchups: withScores(0, 0) }).phase, 'pregame');
});

test('unknown user throws noRosterForUser', () => {
  assert.throws(() => build({ userId: 'nobody' }), (error) => error instanceof MatchupError && error.code === 'noRosterForUser');
});

test('duplicate roster rows: first one wins', () => {
  const duplicated = [...matchups, { roster_id: 1, matchup_id: 1, points: 999 }];
  assert.equal(build({ matchups: duplicated }).me.points, 87.42);
});

test('toContentState matches MatchupActivityAttributes.ContentState', () => {
  const state = toContentState(build());
  assert.deepEqual(state, {
    myPoints: 87.42,
    opponentPoints: 74.1,
    myRecord: '1-0',
    opponentRecord: '0-1',
    phase: 'live',
    updatedAtUnix: sundayAfternoon.getTime() / 1000,
  });
  assert.deepEqual(Object.keys(state), ['myPoints', 'opponentPoints', 'myRecord', 'opponentRecord', 'phase', 'updatedAtUnix']);
});

test('toContentState omits unknown records and uses 0 for a bye', () => {
  // u3 plays the orphaned roster 4, which has no settings → no opponentRecord key.
  const versusOrphan = toContentState(build({ userId: 'u3' }));
  assert.equal('opponentRecord' in versusOrphan, false);
  assert.equal(versusOrphan.myRecord, '1-1-1');
  assert.equal(versusOrphan.opponentPoints, 60);

  const bye = toContentState(build({ matchups: byeMatchups }));
  assert.equal('opponentRecord' in bye, false);
  assert.equal(bye.opponentPoints, 0);
  assert.equal(bye.phase, 'live', 'a bye follows the week phase');
});

test('toAttributes matches MatchupActivityAttributes', () => {
  assert.deepEqual(toAttributes(build()), {
    leagueId: league.league_id,
    leagueName: 'Sunday Scaries',
    season: '2026',
    week: 2,
    myTeamName: 'Gridiron Gurus',
    myAvatarId: 'avatar-1',
    opponentTeamName: 'sam',
  });
  const bye = toAttributes(build({ matchups: byeMatchups }));
  assert.equal(bye.opponentTeamName, 'Bye week');
  assert.equal('opponentAvatarId' in bye, false);
});

test('a co-owner sees the roster as theirs', () => {
  const coOwned = rosters.map((r) => (r.roster_id === 1 ? { ...r, co_owners: ['u9'] } : r));
  const snapshot = buildSnapshot({ userId: 'u9', league, week: 2, rosters: coOwned, users, matchups, now: new Date('2026-09-20T20:00:00Z') });
  assert.equal(snapshot.me.rosterId, 1);
  assert.equal(snapshot.me.name, 'Gridiron Gurus');
});
