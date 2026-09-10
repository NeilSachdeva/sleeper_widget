/**
 * Shared test data: a four-team league in Sleeper's JSON shape, plus fake
 * store / Sleeper / APNs objects so tests never touch the network or disk.
 */

export const LEAGUE_ID = '123456789012345678';

export const league = {
  league_id: LEAGUE_ID,
  name: 'Sunday Scaries',
  season: '2026',
  sport: 'nfl',
  status: 'in_season',
  total_rosters: 4,
  avatar: null,
  settings: { playoff_week_start: 15, leg: 2 },
};

export const users = [
  { user_id: 'u1', display_name: 'neil', avatar: 'avatar-1', metadata: { team_name: 'Gridiron Gurus' }, is_owner: true },
  // Blank team name → falls back to display_name.
  { user_id: 'u2', display_name: 'sam', avatar: null, metadata: { team_name: '   ' }, is_owner: false },
  // No metadata at all → display_name.
  { user_id: 'u3', display_name: 'pat', avatar: 'avatar-3', metadata: null, is_owner: false },
];

export const rosters = [
  { roster_id: 1, owner_id: 'u1', league_id: LEAGUE_ID, settings: { wins: 1, losses: 0, ties: 0, fpts: 87 } },
  { roster_id: 2, owner_id: 'u2', league_id: LEAGUE_ID, settings: { wins: 0, losses: 1, ties: 0, fpts: 74 } },
  { roster_id: 3, owner_id: 'u3', league_id: LEAGUE_ID, settings: { wins: 1, losses: 1, ties: 1 } },
  // Orphaned roster (owner left the league) → "Team 4", no record.
  { roster_id: 4, owner_id: null, league_id: LEAGUE_ID, settings: null },
];

/** Week 2: 1 vs 2, 3 vs 4. */
export const matchups = [
  { roster_id: 1, matchup_id: 1, points: 87.42, custom_points: null },
  { roster_id: 2, matchup_id: 1, points: 74.1, custom_points: null },
  { roster_id: 3, matchup_id: 2, points: 50, custom_points: null },
  { roster_id: 4, matchup_id: 2, points: 60, custom_points: null },
];

/** Roster 1 has no opponent this week. */
export const byeMatchups = [
  { roster_id: 1, matchup_id: null, points: 0, custom_points: null },
  { roster_id: 3, matchup_id: 2, points: 50, custom_points: null },
  { roster_id: 4, matchup_id: 2, points: 60, custom_points: null },
];

/** Same week, but with the given scores for rosters 1 and 2. */
export function withScores(mine, theirs) {
  return matchups.map((m) => {
    if (m.roster_id === 1) return { ...m, points: mine };
    if (m.roster_id === 2) return { ...m, points: theirs };
    return m;
  });
}

export const silentLog = { info() {}, warn() {}, error() {} };

/**
 * In-memory stand-in for lib/store.mjs.
 * @param {object[]} rows
 */
export function fakeStore(rows) {
  const map = new Map(rows.map((row) => [row.installId, { ...emptyBookkeeping(), ...row }]));
  return {
    all: () => [...map.values()].map((row) => ({ ...row })),
    get: (installId) => map.get(installId) ?? null,
    size: () => map.size,
    patch(installId, fields) {
      const row = map.get(installId);
      Object.assign(row, fields);
      return row;
    },
  };
}

export function emptyBookkeeping() {
  return {
    pushToStartToken: null,
    activityToken: null,
    activityId: null,
    environment: 'development',
    timeZone: 'America/New_York',
    startedManually: false,
    lastContentStateHash: null,
    lastPushAt: null,
    lastStartPushAt: null,
    lastStartKey: null,
    lastPhase: null,
    lastMargin: null,
  };
}

/**
 * Sleeper client returning canned data.
 * @param {{ week?: number, matchups?: object[], state?: object }} [overrides]
 */
export function fakeSleeper({ week = 2, matchups: weekMatchups = matchups, state } = {}) {
  const calls = [];
  const weeksRequested = [];
  const record = (name, value) => {
    calls.push(name);
    return Promise.resolve(value);
  };
  return {
    calls,
    weeksRequested,
    state: () => record('state', state ?? { week, display_week: week, season: '2026', season_type: 'regular', league_season: '2026' }),
    league: () => record('league', league),
    rosters: () => record('rosters', rosters),
    users: () => record('users', users),
    matchups: (_leagueId, requestedWeek) => {
      weeksRequested.push(requestedWeek);
      return record('matchups', weekMatchups);
    },
  };
}

/**
 * APNs client that records sends and answers from a queue of partial results.
 * @param {object[]} [responses] e.g. `[{ status: 410, tokenDead: true }]`
 */
export function fakeApns(responses = []) {
  const sent = [];
  const queue = [...responses];
  return {
    sent,
    async sendLiveActivityPush(input) {
      sent.push(input);
      const override = queue.shift() ?? {};
      const status = override.status ?? 200;
      return {
        status,
        body: '',
        apnsId: 'fake-apns-id',
        reason: null,
        ok: status >= 200 && status < 300,
        tokenDead: false,
        ...override,
      };
    },
  };
}
