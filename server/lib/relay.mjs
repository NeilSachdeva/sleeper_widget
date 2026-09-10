/**
 * The decision loop. One `tick` looks at every registration, fetches the
 * matchup once per league, and sends at most one push per registration:
 *
 * - running activity (`activityToken`): `update` when the content-state changed,
 *   a low-priority heartbeat every 20 min inside a game window, or `end` once the
 *   game window is over (or the matchup is final). One activity per window keeps
 *   well inside Apple's 8-hour limit; the next window starts a fresh one.
 *   An activity the user started by hand (`startedManually`) mirrors the app's
 *   `reconcile`: it is only ended when the matchup is final, and it keeps getting
 *   heartbeats outside game windows so its stale-date keeps moving.
 * - no activity but a `pushToStartToken`: `start` inside a game window, unless
 *   it is a bye week or we already sent a start for this league+week in the last
 *   30 minutes.
 * - a token APNs reports as dead is cleared so we stop sending to it.
 */

import crypto from 'node:crypto';
import { currentWindow } from './gameWindow.mjs';
import { buildSnapshot, margin, toAttributes, toContentState } from './matchup.mjs';
import { endPayload, leadChangeAlert, startPayload, unixSeconds, updatePayload } from './payloads.mjs';

export const HEARTBEAT_MS = 20 * 60 * 1000;
export const START_COOLDOWN_MS = 30 * 60 * 1000;
export const EXPIRATION_S = 30 * 60;

/**
 * @typedef {object} TickSummary
 * @property {number} registrations
 * @property {number} pushes
 * @property {number} errors
 */

/**
 * Hash of the parts of a content-state worth pushing for. `updatedAtUnix` is
 * excluded on purpose: it changes every tick and would defeat the comparison.
 * @param {import('./matchup.mjs').ContentState} contentState
 * @returns {string}
 */
export function contentStateHash(contentState) {
  const { myPoints, opponentPoints, myRecord = null, opponentRecord = null, phase } = contentState;
  return crypto
    .createHash('sha1')
    .update(JSON.stringify({ myPoints, opponentPoints, myRecord, opponentRecord, phase }))
    .digest('hex');
}

/**
 * Port of `SleeperState.currentWeek`: the week Sleeper itself shows.
 * `display_week` can run ahead of `week` around the Tuesday rollover, so it wins when present.
 * @param {{ week?: number, display_week?: number | null }} state `GET /state/nfl`
 * @returns {number} at least 1
 */
export function currentWeek(state) {
  return Math.max(1, Number(state.display_week ?? state.week) || 0);
}

/**
 * Runs one poll cycle.
 * @param {object} input
 * @param {import('./store.mjs').Store} input.store
 * @param {import('./sleeper.mjs').SleeperClient} input.sleeper
 * @param {import('./apns.mjs').ApnsClient} input.apns
 * @param {Date} [input.now]
 * @param {{ info: Function, warn: Function, error: Function }} [input.log]
 * @returns {Promise<TickSummary>}
 */
export async function tick({ store, sleeper, apns, now = new Date(), log = console }) {
  const registrations = store.all();
  const summary = { registrations: registrations.length, pushes: 0, errors: 0 };
  if (registrations.length === 0) return summary;

  let week;
  try {
    week = currentWeek(await sleeper.state('nfl'));
  } catch (error) {
    summary.errors += 1;
    log.error(`tick: could not load Sleeper state: ${error.message}`);
    return summary;
  }

  // One fetch per league per tick, shared by every registration in that league.
  const leagues = new Map();
  const loadLeague = (leagueId) => {
    if (!leagues.has(leagueId)) {
      leagues.set(
        leagueId,
        Promise.all([
          sleeper.league(leagueId),
          sleeper.rosters(leagueId),
          sleeper.users(leagueId),
          sleeper.matchups(leagueId, week),
        ]).then(([league, rosters, users, matchups]) => ({ league, rosters, users, matchups })),
      );
    }
    return leagues.get(leagueId);
  };

  for (const registration of registrations) {
    try {
      const pushed = await processRegistration({ registration, week, loadLeague, store, apns, now, log });
      if (pushed) summary.pushes += 1;
    } catch (error) {
      summary.errors += 1;
      log.error(`tick: ${registration.installId} (league ${registration.leagueId}): ${error.message}`);
    }
  }
  return summary;
}

/** @returns {Promise<boolean>} true when a push was sent */
async function processRegistration({ registration, week, loadLeague, store, apns, now, log }) {
  const data = await loadLeague(registration.leagueId);
  const snapshot = buildSnapshot({ userId: registration.userId, ...data, week, now });
  const contentState = toContentState(snapshot);
  const attributes = toAttributes(snapshot);
  const inWindow = currentWindow(now, snapshot.week) !== null;
  const hash = contentStateHash(contentState);
  const matchupFields = { lastPhase: snapshot.phase, lastMargin: margin(snapshot) };

  if (registration.activityToken) {
    const manual = registration.startedManually === true;
    const shouldEnd = snapshot.phase === 'final' || (!manual && !inWindow);
    if (shouldEnd) {
      const result = await push({
        apns, log, registration, now, kind: 'end', priority: 10,
        token: registration.activityToken,
        payload: endPayload({ contentState, now }),
      });
      if (result.ok || result.tokenDead) {
        store.patch(registration.installId, {
          ...matchupFields, activityToken: null, activityId: null, lastContentStateHash: null, lastPushAt: null,
        });
      }
      return true;
    }

    const changed = hash !== registration.lastContentStateHash;
    const heartbeatDue = (inWindow || manual) && elapsed(registration.lastPushAt, now) >= HEARTBEAT_MS;
    if (!changed && !heartbeatDue) return false;

    const alert = changed
      ? leadChangeAlert({ previousMargin: registration.lastMargin, contentState, attributes })
      : null;
    const result = await push({
      apns, log, registration, now, kind: changed ? 'update' : 'heartbeat', priority: changed ? 10 : 5,
      token: registration.activityToken,
      payload: updatePayload({ contentState, now, inWindow, alert }),
    });
    if (result.ok) {
      store.patch(registration.installId, {
        ...matchupFields, lastContentStateHash: hash, lastPushAt: now.toISOString(),
      });
    } else if (result.tokenDead) {
      store.patch(registration.installId, {
        activityToken: null, activityId: null, lastContentStateHash: null, lastPushAt: null,
      });
    }
    return true;
  }

  if (registration.pushToStartToken && inWindow && snapshot.opponent !== null) {
    const startKey = `${snapshot.leagueId}:${snapshot.week}`;
    const recentlyStarted =
      registration.lastStartKey === startKey && elapsed(registration.lastStartPushAt, now) < START_COOLDOWN_MS;
    if (recentlyStarted) return false;

    const result = await push({
      apns, log, registration, now, kind: 'start', priority: 10,
      token: registration.pushToStartToken,
      payload: startPayload({ contentState, attributes, now, inWindow }),
    });
    if (result.ok) {
      store.patch(registration.installId, {
        ...matchupFields, lastStartPushAt: now.toISOString(), lastStartKey: startKey,
      });
    } else if (result.tokenDead) {
      store.patch(registration.installId, { pushToStartToken: null });
    }
    return true;
  }

  return false;
}

async function push({ apns, log, registration, now, kind, priority, token, payload }) {
  const result = await apns.sendLiveActivityPush({
    token,
    environment: registration.environment,
    payload,
    priority,
    expiration: unixSeconds(now) + EXPIRATION_S,
  });
  const detail = [
    `push=${kind}`,
    `install=${registration.installId}`,
    `league=${registration.leagueId}`,
    `env=${registration.environment}`,
    `priority=${priority}`,
    `status=${result.status}`,
  ];
  if (result.reason) detail.push(`reason=${result.reason}`);
  if (result.apnsId) detail.push(`apns-id=${result.apnsId}`);
  if (result.tokenDead) detail.push('token=dead');
  if (result.ok) log.info(detail.join(' '));
  else log.warn(detail.join(' '));
  return result;
}

/** Milliseconds since an ISO timestamp; Infinity when unknown. */
function elapsed(isoTime, now) {
  if (!isoTime) return Infinity;
  const then = Date.parse(isoTime);
  return Number.isNaN(then) ? Infinity : now.getTime() - then;
}
