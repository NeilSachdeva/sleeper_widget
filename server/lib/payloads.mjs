/**
 * APNs Live Activity payloads. Pure functions; shapes follow Apple's
 * "Starting and updating Live Activities with ActivityKit push notifications"
 * and the Swift types in Shared/MatchupActivityAttributes.swift.
 */

/** Same as `AppConfig.liveActivityStaleInterval` in the app. */
export const STALE_AFTER_MS = 30 * 60 * 1000;
/** How long the ended activity stays on the Lock Screen. */
export const DISMISS_AFTER_MS = 30 * 60 * 1000;
/** Apple rejects Live Activity pushes larger than this. */
export const MAX_PAYLOAD_BYTES = 4096;
/** Swift type name the start payload targets (`attributes-type`). */
export const ATTRIBUTES_TYPE = 'MatchupActivityAttributes';

/**
 * @typedef {import('./matchup.mjs').ContentState} ContentState
 * @typedef {import('./matchup.mjs').Attributes} Attributes
 */

/**
 * @typedef {object} Alert
 * @property {string} title
 * @property {string} body
 */

/**
 * @param {Date} date
 * @returns {number} whole unix seconds
 */
export function unixSeconds(date) {
  return Math.floor(date.getTime() / 1000);
}

/**
 * Mirrors `LiveActivityManager.content(for:)`: the activity ranks highest while
 * games are on, lower the rest of the week.
 * @param {boolean} inWindow
 * @returns {number}
 */
export function relevanceScore(inWindow) {
  return inWindow ? 100 : 50;
}

/**
 * `event: "update"` payload for a running activity.
 * @param {object} input
 * @param {ContentState} input.contentState
 * @param {Date} input.now
 * @param {boolean} [input.inWindow] whether `now` is inside a game window
 * @param {Alert | null} [input.alert] only when the lead changes hands
 * @returns {object}
 */
export function updatePayload({ contentState, now, inWindow = true, alert = null }) {
  const aps = {
    timestamp: unixSeconds(now),
    event: 'update',
    'content-state': contentState,
    'stale-date': unixSeconds(new Date(now.getTime() + STALE_AFTER_MS)),
    'relevance-score': relevanceScore(inWindow),
  };
  if (alert) aps.alert = alert;
  return { aps };
}

/**
 * `event: "start"` (push-to-start) payload, sent to the push-to-start token.
 * @param {object} input
 * @param {ContentState} input.contentState
 * @param {Attributes} input.attributes
 * @param {Date} input.now
 * @param {boolean} [input.inWindow] whether `now` is inside a game window
 * @returns {object}
 */
export function startPayload({ contentState, attributes, now, inWindow = true }) {
  return {
    aps: {
      timestamp: unixSeconds(now),
      event: 'start',
      'content-state': contentState,
      'attributes-type': ATTRIBUTES_TYPE,
      attributes,
      alert: {
        title: attributes.leagueName,
        body: `Week ${attributes.week}: ${attributes.myTeamName} vs ${attributes.opponentTeamName}`,
      },
      'relevance-score': relevanceScore(inWindow),
      'stale-date': unixSeconds(new Date(now.getTime() + STALE_AFTER_MS)),
    },
  };
}

/**
 * `event: "end"` payload with the final state.
 * @param {object} input
 * @param {ContentState} input.contentState
 * @param {Date} input.now
 * @returns {object}
 */
export function endPayload({ contentState, now }) {
  return {
    aps: {
      timestamp: unixSeconds(now),
      event: 'end',
      'content-state': contentState,
      'dismissal-date': unixSeconds(new Date(now.getTime() + DISMISS_AFTER_MS)),
    },
  };
}

/**
 * Alert to attach to an update when my team goes from trailing/tied to leading
 * or the other way round. Null otherwise (or when there is no previous margin).
 * @param {object} input
 * @param {number | null | undefined} input.previousMargin
 * @param {ContentState} input.contentState
 * @param {Attributes} input.attributes
 * @returns {Alert | null}
 */
export function leadChangeAlert({ previousMargin, contentState, attributes }) {
  if (previousMargin === null || previousMargin === undefined) return null;
  const currentMargin = contentState.myPoints - contentState.opponentPoints;
  const wasLeading = previousMargin > 0;
  const isLeading = currentMargin > 0;
  if (wasLeading === isLeading) return null;

  let title;
  if (isLeading) title = 'You took the lead';
  else if (currentMargin === 0) title = 'All tied up';
  else title = 'You lost the lead';

  const body =
    `${attributes.myTeamName} ${formatPoints(contentState.myPoints)} - ` +
    `${formatPoints(contentState.opponentPoints)} ${attributes.opponentTeamName}`;
  return { title, body };
}

/**
 * Serialized size, for the 4 KB check.
 * @param {object} payload
 * @returns {number}
 */
export function payloadBytes(payload) {
  return Buffer.byteLength(JSON.stringify(payload), 'utf8');
}

/**
 * Port of `ScoreFormat.points`: "104.3", not "104.30000000000001".
 * @param {number} value
 * @returns {string}
 */
export function formatPoints(value) {
  const rounded = Math.round(value * 100) / 100;
  if (Number.isInteger(rounded)) return String(rounded);
  let text = rounded.toFixed(2);
  while (text.endsWith('0')) text = text.slice(0, -1);
  if (text.endsWith('.')) text = text.slice(0, -1);
  return text;
}
