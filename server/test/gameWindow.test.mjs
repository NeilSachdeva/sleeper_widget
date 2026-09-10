import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  currentWindow,
  easternDate,
  easternParts,
  holidayLabel,
  isLiveSpan,
  nextWindow,
  phase,
  weekAnchor,
  windows,
} from '../lib/gameWindow.mjs';

// Same fixtures as SleeperWidgetTests/GameWindowTests.swift.
const eastern = easternDate;

function assertSameInstant(actual, expected, message) {
  assert.equal(actual?.toISOString(), expected.toISOString(), message);
}

test('easternDate converts wall-clock times on both sides of DST', () => {
  assert.equal(eastern(2026, 9, 20, 16).toISOString(), '2026-09-20T20:00:00.000Z', 'EDT is UTC-4');
  assert.equal(eastern(2026, 10, 31, 9).toISOString(), '2026-10-31T13:00:00.000Z', 'day before DST ends');
  assert.equal(eastern(2026, 11, 1, 9).toISOString(), '2026-11-01T14:00:00.000Z', 'EST is UTC-5');
  assert.equal(eastern(2026, 11, 1, 0, 45).toISOString(), '2026-11-01T04:45:00.000Z', 'before the 02:00 fall-back');
  // Day overflow is how day arithmetic is done.
  assert.equal(eastern(2026, 9, 32, 12).toISOString(), eastern(2026, 10, 2, 12).toISOString());
});

test('easternParts reports Eastern wall clock and weekday', () => {
  const parts = easternParts(new Date('2026-09-20T20:00:00Z'));
  assert.deepEqual(parts, { year: 2026, month: 9, day: 20, hour: 16, minute: 0, second: 0, weekday: 0 });
});

test('weekAnchor is the preceding Tuesday 05:00 ET', () => {
  assertSameInstant(weekAnchor(eastern(2026, 9, 20, 16)), eastern(2026, 9, 15, 5));
  assertSameInstant(weekAnchor(eastern(2026, 9, 22, 3)), eastern(2026, 9, 15, 5), 'Tuesday 03:00 belongs to the previous week');
  assertSameInstant(weekAnchor(eastern(2026, 9, 22, 6)), eastern(2026, 9, 22, 5), 'Tuesday 06:00 starts the new week');
});

test('Sunday afternoon is in the Sunday window', () => {
  assert.equal(currentWindow(eastern(2026, 9, 20, 16), 2)?.label, 'Sunday');
});

test('Thursday night and Monday night', () => {
  assert.equal(currentWindow(eastern(2026, 9, 17, 21), 2)?.label, 'Thursday Night');
  assert.equal(currentWindow(eastern(2026, 9, 21, 22), 2)?.label, 'Monday Night');
  assert.equal(currentWindow(eastern(2026, 9, 22, 0, 30), 2)?.label, 'Monday Night', 'just past midnight still counts');
});

test('no window midweek, Sunday morning, or Saturday early in the season', () => {
  assert.equal(currentWindow(eastern(2026, 9, 23, 12), 2), null);
  assert.equal(currentWindow(eastern(2026, 9, 20, 7), 2), null);
  assert.equal(currentWindow(eastern(2026, 9, 19, 15), 2), null, 'no Saturday games early in the season');
});

test('Saturday window late in the season', () => {
  assert.equal(currentWindow(eastern(2026, 12, 19, 15), 15)?.label, 'Saturday');
  assert.equal(windows(eastern(2026, 12, 19, 15), 15).map((w) => w.label).join(','), 'Thursday Night,Saturday,Sunday,Monday Night');
  assert.equal(windows(eastern(2026, 9, 20, 15), 2).map((w) => w.label).join(','), 'Thursday Night,Sunday,Monday Night');
});

test('window boundaries match the Swift definition', () => {
  const [thursday, sunday, monday] = windows(eastern(2026, 9, 20, 16), 2);
  assertSameInstant(thursday.start, eastern(2026, 9, 17, 19, 30));
  assertSameInstant(thursday.end, eastern(2026, 9, 18, 0, 45));
  assertSameInstant(sunday.start, eastern(2026, 9, 20, 9, 0));
  assertSameInstant(sunday.end, eastern(2026, 9, 21, 0, 45));
  assertSameInstant(monday.start, eastern(2026, 9, 21, 19, 30));
  assertSameInstant(monday.end, eastern(2026, 9, 22, 0, 45));
});

test('next window from midweek is Thursday', () => {
  const next = nextWindow(eastern(2026, 9, 16, 12), 2);
  assert.equal(next?.label, 'Thursday Night');
  assertSameInstant(next.start, eastern(2026, 9, 17, 19, 30));
});

test('next window rolls into the following week', () => {
  const next = nextWindow(eastern(2026, 9, 22, 3), 2);
  assert.equal(next?.label, 'Thursday Night');
  assertSameInstant(next.start, eastern(2026, 9, 24, 19, 30));
});

test('live span', () => {
  assert.equal(isLiveSpan(eastern(2026, 9, 18, 12)), true, 'Friday is inside the live span');
  assert.equal(isLiveSpan(eastern(2026, 9, 16, 12)), false, 'Wednesday is between weeks');
  assert.equal(isLiveSpan(eastern(2026, 9, 22, 3)), false, 'Tuesday 3am is after the span ends');
  assert.equal(isLiveSpan(eastern(2026, 9, 22, 1, 59)), true, 'Tuesday 01:59 is still in');
});

test('phase derivation', () => {
  assert.equal(phase(0, 0, eastern(2026, 9, 16, 12)), 'pregame');
  assert.equal(phase(0, 0, eastern(2026, 9, 20, 13)), 'live');
  assert.equal(phase(90, 80, eastern(2026, 9, 22, 12)), 'final');
});

test('DST transition keeps wall-clock times', () => {
  // DST ends Sunday Nov 1, 2026; the Sunday window still starts at 09:00 local.
  const window = currentWindow(eastern(2026, 11, 1, 13), 8);
  assert.equal(window?.label, 'Sunday');
  assertSameInstant(window.start, eastern(2026, 11, 1, 9));
  assert.equal(window.start.toISOString(), '2026-11-01T14:00:00.000Z');
  // Thursday of that same week was still on EDT.
  const [thursday] = windows(eastern(2026, 11, 1, 13), 8);
  assert.equal(thursday.start.toISOString(), '2026-10-29T23:30:00.000Z');
});

test('Thanksgiving afternoon is a live window (mirrors GameWindowTests)', () => {
  // Thanksgiving 2026 is Thu Nov 26 (12:30 / 16:30 / 20:20 ET kickoffs).
  assert.equal(holidayLabel(eastern(2026, 11, 26, 12)), 'Thanksgiving');
  assert.equal(holidayLabel(eastern(2026, 11, 19, 12)), null, 'the Thursday before is ordinary');
  assert.equal(phase(8.4, 0, eastern(2026, 11, 26, 14)), 'live');
  assert.equal(currentWindow(eastern(2026, 11, 26, 14), 12)?.label, 'Thanksgiving');
  assert.equal(isLiveSpan(eastern(2026, 11, 26, 12, 30)), true);
  assert.equal(isLiveSpan(eastern(2026, 11, 26, 11)), false);
  assert.equal(currentWindow(eastern(2026, 11, 19, 14), 11), null, 'an ordinary Thursday afternoon stays off');
  assert.equal(windows(eastern(2026, 11, 26, 14), 12).map((w) => w.label).join(','), 'Thanksgiving,Sunday,Monday Night');
});

test('Christmas on a Wednesday or Thursday is a live window', () => {
  // Christmas 2030 falls on a Wednesday.
  assert.equal(phase(10, 0, eastern(2030, 12, 25, 14)), 'live');
  assert.equal(currentWindow(eastern(2030, 12, 25, 14), 17)?.label, 'Christmas');
  assert.equal(currentWindow(eastern(2030, 12, 26, 21), 17)?.label, 'Thursday Night');
  assert.equal(windows(eastern(2030, 12, 25, 14), 17).map((w) => w.label).join(','), 'Christmas,Thursday Night,Saturday,Sunday,Monday Night');
  // Christmas 2025 falls on a Thursday and replaces the night window.
  assert.equal(currentWindow(eastern(2025, 12, 25, 14), 17)?.label, 'Christmas');
  assert.equal(windows(eastern(2025, 12, 25, 14), 17).map((w) => w.label).join(','), 'Christmas,Saturday,Sunday,Monday Night');
  // Christmas on a Friday (2026) is an ordinary week.
  assert.equal(holidayLabel(eastern(2026, 12, 25, 14)), null);
});

test('a week whose only scoring is negative is final, not pregame', () => {
  assert.equal(phase(-1.2, 0, eastern(2026, 9, 23, 12)), 'final');
  assert.equal(phase(0, 0, eastern(2026, 9, 23, 12)), 'pregame');
});
