/**
 * Port of Shared/GameWindow.swift.
 *
 * Approximates when NFL games are on, in US Eastern time, so the relay knows when
 * a matchup Live Activity is relevant without a schedule feed. A fantasy week is
 * treated as running from Tuesday 05:00 ET to the following Tuesday 05:00 ET
 * (Sleeper advances its week early Tuesday morning).
 *
 * All wall-clock math goes through `easternDate`, which turns an Eastern wall
 * time into a UTC `Date` using `Intl.DateTimeFormat`, so DST is handled without
 * any library.
 */

export const EASTERN_ZONE = 'America/New_York';

const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];

const formatter = new Intl.DateTimeFormat('en-US', {
  timeZone: EASTERN_ZONE,
  hourCycle: 'h23',
  year: 'numeric',
  month: 'numeric',
  day: 'numeric',
  hour: 'numeric',
  minute: 'numeric',
  second: 'numeric',
  weekday: 'short',
});

/**
 * @typedef {object} Window
 * @property {Date} start inclusive
 * @property {Date} end exclusive
 * @property {string} label e.g. "Sunday"
 */

/**
 * @typedef {object} EasternParts
 * @property {number} year
 * @property {number} month 1-12
 * @property {number} day 1-31
 * @property {number} hour 0-23
 * @property {number} minute
 * @property {number} second
 * @property {number} weekday 0 = Sunday ... 6 = Saturday
 */

/**
 * Wall-clock components of `date` in Eastern time.
 * @param {Date} date
 * @returns {EasternParts}
 */
export function easternParts(date) {
  const parts = {};
  for (const { type, value } of formatter.formatToParts(date)) {
    if (type === 'weekday') parts.weekday = WEEKDAYS.indexOf(value);
    else if (type !== 'literal') parts[type] = Number(value);
  }
  return parts;
}

/**
 * The instant at which the Eastern wall clock reads the given components.
 * `day` may overflow its month (e.g. day 35), which is how day arithmetic is done here.
 * @param {number} year
 * @param {number} month 1-12
 * @param {number} day
 * @param {number} [hour]
 * @param {number} [minute]
 * @param {number} [second]
 * @returns {Date}
 */
export function easternDate(year, month, day, hour = 0, minute = 0, second = 0) {
  const wanted = Date.UTC(year, month - 1, day, hour, minute, second);
  let guess = wanted;
  // Guess that ET == UTC, read back what ET wall time that guess produced, and
  // shift by the difference. Two passes settle it on either side of a DST change.
  for (let pass = 0; pass < 2; pass += 1) {
    const seen = easternParts(new Date(guess));
    const seenAsUtc = Date.UTC(seen.year, seen.month - 1, seen.day, seen.hour, seen.minute, seen.second);
    guess += wanted - seenAsUtc;
  }
  return new Date(guess);
}

/**
 * 05:00 ET on the Tuesday that starts the fantasy week containing `date`.
 * @param {Date} date
 * @returns {Date}
 */
export function weekAnchor(date) {
  const p = easternParts(date);
  const daysSinceTuesday = (p.weekday - 2 + 7) % 7;
  const anchor = easternDate(p.year, p.month, p.day - daysSinceTuesday, 5, 0);
  if (date < anchor) {
    return easternDate(p.year, p.month, p.day - daysSinceTuesday - 7, 5, 0);
  }
  return anchor;
}

/**
 * Game windows for the fantasy week containing `date`, in chronological order.
 * Saturday games only appear late in the season (weeks 15+).
 * @param {Date} date
 * @param {number} week
 * @returns {Window[]}
 */
export function windows(date, week) {
  const tuesday = easternParts(weekAnchor(date));
  const at = (dayOffset, hour, minute) =>
    easternDate(tuesday.year, tuesday.month, tuesday.day + dayOffset, hour, minute);

  const list = [{ start: at(2, 19, 30), end: at(3, 0, 45), label: 'Thursday Night' }];
  if (week >= 15) {
    list.push({ start: at(4, 12, 30), end: at(5, 0, 45), label: 'Saturday' });
  }
  list.push({ start: at(5, 9, 0), end: at(6, 0, 45), label: 'Sunday' });
  list.push({ start: at(6, 19, 30), end: at(7, 0, 45), label: 'Monday Night' });
  return list;
}

/**
 * @param {Window} window
 * @param {Date} date
 * @returns {boolean}
 */
export function contains(window, date) {
  return date >= window.start && date < window.end;
}

/**
 * The window that is on at `date`, or null.
 * @param {Date} date
 * @param {number} week
 * @returns {Window | null}
 */
export function currentWindow(date, week) {
  return windows(date, week).find((w) => contains(w, date)) ?? null;
}

/**
 * The next window that starts after `date` (looks ahead one extra week).
 * @param {Date} date
 * @param {number} week
 * @returns {Window | null}
 */
export function nextWindow(date, week) {
  const upcoming = windows(date, week).find((w) => w.start > date);
  if (upcoming) return upcoming;
  const p = easternParts(date);
  const nextWeek = easternDate(p.year, p.month, p.day + 7, p.hour, p.minute, p.second);
  return windows(nextWeek, week + 1).find((w) => w.start > date) ?? null;
}

/**
 * True from Thursday kickoff through the end of Monday night (Tuesday 02:00 ET),
 * i.e. while the week's scores can still change.
 * @param {Date} date
 * @returns {boolean}
 */
export function isLiveSpan(date) {
  const tuesday = easternParts(weekAnchor(date));
  const spanStart = easternDate(tuesday.year, tuesday.month, tuesday.day + 2, 19, 30);
  const spanEnd = easternDate(tuesday.year, tuesday.month, tuesday.day + 7, 2, 0);
  return date >= spanStart && date < spanEnd;
}

/**
 * Derives the matchup phase from scores and the time of week.
 * @param {number} myPoints
 * @param {number} opponentPoints
 * @param {Date} date
 * @returns {'pregame' | 'live' | 'final'}
 */
export function phase(myPoints, opponentPoints, date) {
  const anyPoints = myPoints > 0 || opponentPoints > 0;
  if (isLiveSpan(date)) return 'live';
  return anyPoints ? 'final' : 'pregame';
}
