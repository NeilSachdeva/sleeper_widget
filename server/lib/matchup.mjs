/**
 * Port of `MatchupBuilder.build` from Shared/MatchupService.swift, plus the two
 * projections used by the Live Activity contract in Shared/MatchupActivityAttributes.swift.
 *
 * Input objects are raw Sleeper JSON (snake_case); output mirrors `MatchupSnapshot`.
 */

import { phase as gamePhase } from './gameWindow.mjs';

/**
 * @typedef {object} Team
 * @property {number} rosterId
 * @property {string} name
 * @property {string | null} ownerName
 * @property {string | null} avatarId
 * @property {number} points
 * @property {string | null} record
 */

/**
 * @typedef {object} Snapshot
 * @property {string} leagueId
 * @property {string} leagueName
 * @property {string} season
 * @property {number} week
 * @property {Team} me
 * @property {Team | null} opponent null on a bye week
 * @property {'pregame' | 'live' | 'final'} phase
 * @property {Date} updatedAt
 */

/**
 * @typedef {object} ContentState
 * @property {number} myPoints
 * @property {number} opponentPoints
 * @property {string} [myRecord]
 * @property {string} [opponentRecord]
 * @property {'pregame' | 'live' | 'final'} phase
 * @property {number} updatedAtUnix
 */

/**
 * @typedef {object} Attributes
 * @property {string} leagueId
 * @property {string} leagueName
 * @property {string} season
 * @property {number} week
 * @property {string} myTeamName
 * @property {string} [myAvatarId]
 * @property {string} opponentTeamName
 * @property {string} [opponentAvatarId]
 */

export class MatchupError extends Error {
  /**
   * @param {'noRosterForUser'} code
   * @param {string} message
   */
  constructor(code, message) {
    super(message);
    this.name = 'MatchupError';
    this.code = code;
  }
}

/**
 * Builds a snapshot from Sleeper responses. Pure: no I/O.
 * @param {object} input
 * @param {string} input.userId
 * @param {object} input.league `GET /league/<id>`
 * @param {number} input.week
 * @param {object[]} input.rosters `GET /league/<id>/rosters`
 * @param {object[]} input.users `GET /league/<id>/users`
 * @param {object[]} input.matchups `GET /league/<id>/matchups/<week>`
 * @param {Date} [input.now]
 * @returns {Snapshot}
 */
export function buildSnapshot({ userId, league, week, rosters, users, matchups, now = new Date() }) {
  const myRoster = rosters.find((r) => r.owner_id === userId);
  if (!myRoster) {
    throw new MatchupError('noRosterForUser', "You don't have a team in this league.");
  }

  const usersById = firstById(users, (u) => u.user_id);
  const rostersById = firstById(rosters, (r) => r.roster_id);
  const matchupsByRoster = firstById(matchups, (m) => m.roster_id);

  const myMatchup = matchupsByRoster.get(myRoster.roster_id) ?? null;
  const me = team(myRoster, myMatchup, usersById);

  let opponent = null;
  const matchupId = myMatchup?.matchup_id ?? null;
  if (matchupId !== null) {
    const theirs = matchups.find((m) => m.matchup_id === matchupId && m.roster_id !== myRoster.roster_id);
    const theirRoster = theirs ? rostersById.get(theirs.roster_id) : undefined;
    if (theirs && theirRoster) {
      opponent = team(theirRoster, theirs, usersById);
    }
  }

  const phase = opponent === null ? 'pregame' : gamePhase(me.points, opponent.points, now);

  return {
    leagueId: league.league_id,
    leagueName: league.name,
    season: league.season,
    week,
    me,
    opponent,
    phase,
    updatedAt: now,
  };
}

/**
 * Positive when I'm ahead. Mirrors `MatchupSnapshot.margin`.
 * @param {Snapshot} snapshot
 * @returns {number}
 */
export function margin(snapshot) {
  return snapshot.me.points - (snapshot.opponent?.points ?? 0);
}

/**
 * Dynamic state for a Live Activity (`MatchupActivityAttributes.ContentState`).
 * Optional strings are omitted rather than sent as null.
 * @param {Snapshot} snapshot
 * @returns {ContentState}
 */
export function toContentState(snapshot) {
  return compact({
    myPoints: snapshot.me.points,
    opponentPoints: snapshot.opponent?.points ?? 0,
    myRecord: snapshot.me.record,
    opponentRecord: snapshot.opponent?.record,
    phase: snapshot.phase,
    updatedAtUnix: snapshot.updatedAt.getTime() / 1000,
  });
}

/**
 * Fixed attributes for a Live Activity (`MatchupActivityAttributes`).
 * @param {Snapshot} snapshot
 * @returns {Attributes}
 */
export function toAttributes(snapshot) {
  return compact({
    leagueId: snapshot.leagueId,
    leagueName: snapshot.leagueName,
    season: snapshot.season,
    week: snapshot.week,
    myTeamName: snapshot.me.name,
    myAvatarId: snapshot.me.avatarId,
    opponentTeamName: snapshot.opponent?.name ?? 'Bye week',
    opponentAvatarId: snapshot.opponent?.avatarId,
  });
}

// MARK: - Helpers

/** @returns {Team} */
function team(roster, matchup, usersById) {
  const owner = roster.owner_id != null ? usersById.get(roster.owner_id) : undefined;
  return {
    rosterId: roster.roster_id,
    name: owner ? ownerTeamName(owner) : `Team ${roster.roster_id}`,
    ownerName: owner?.display_name ?? null,
    avatarId: owner?.avatar ?? null,
    points: matchup ? effectivePoints(matchup) : 0,
    record: roster.settings ? recordText(roster.settings) : null,
  };
}

/** Team name if the manager set one, otherwise their display name. */
function ownerTeamName(user) {
  const name = user.metadata?.team_name;
  if (typeof name === 'string' && name.replace(/[\p{Zs}\t]/gu, '') !== '') return name;
  return user.display_name ?? 'Team';
}

/** Commissioner overrides win over computed points. */
function effectivePoints(matchup) {
  return matchup.custom_points ?? matchup.points ?? 0;
}

/** "3-1" or "3-1-1" when there are ties. */
function recordText(settings) {
  const w = settings.wins ?? 0;
  const l = settings.losses ?? 0;
  const t = settings.ties ?? 0;
  return t > 0 ? `${w}-${l}-${t}` : `${w}-${l}`;
}

/** Map keyed by `key(item)`; the first item wins on duplicates, like Swift's `uniquingKeysWith`. */
function firstById(items, key) {
  const map = new Map();
  for (const item of items) {
    const k = key(item);
    if (!map.has(k)) map.set(k, item);
  }
  return map;
}

/** Drops null/undefined values so optional Swift fields are simply absent. */
function compact(object) {
  return Object.fromEntries(Object.entries(object).filter(([, v]) => v !== null && v !== undefined));
}
