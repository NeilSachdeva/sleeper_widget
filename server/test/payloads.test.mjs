import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  ATTRIBUTES_TYPE,
  MAX_PAYLOAD_BYTES,
  endPayload,
  formatPoints,
  leadChangeAlert,
  payloadBytes,
  relevanceScore,
  startPayload,
  unixSeconds,
  updatePayload,
} from '../lib/payloads.mjs';

const now = new Date('2026-09-20T20:00:00.123Z');
const contentState = {
  myPoints: 87.42,
  opponentPoints: 74.1,
  myRecord: '1-0',
  opponentRecord: '0-1',
  phase: 'live',
  updatedAtUnix: now.getTime() / 1000,
};
const attributes = {
  leagueId: '123456789012345678',
  leagueName: 'Sunday Scaries',
  season: '2026',
  week: 2,
  myTeamName: 'Gridiron Gurus',
  myAvatarId: 'avatar-1',
  opponentTeamName: 'Couch Potatoes',
};

test('update payload shape', () => {
  const payload = updatePayload({ contentState, now });
  assert.deepEqual(payload, {
    aps: {
      timestamp: 1789934400,
      event: 'update',
      'content-state': contentState,
      'stale-date': 1789934400 + 30 * 60,
      'relevance-score': 100,
    },
  });
  assert.equal(unixSeconds(now), 1789934400);
  assert.equal(Number.isInteger(payload.aps.timestamp), true);
});

test('relevance-score mirrors the app: 100 inside a game window, 50 outside', () => {
  assert.equal(relevanceScore(true), 100);
  assert.equal(relevanceScore(false), 50);
  assert.equal(updatePayload({ contentState, now, inWindow: true }).aps['relevance-score'], 100);
  assert.equal(updatePayload({ contentState, now, inWindow: false }).aps['relevance-score'], 50);
  assert.equal(updatePayload({ contentState, now }).aps['relevance-score'], 100, 'defaults to in-window');
  assert.equal(startPayload({ contentState, attributes, now, inWindow: true }).aps['relevance-score'], 100);
  assert.equal(startPayload({ contentState, attributes, now, inWindow: false }).aps['relevance-score'], 50);
  assert.equal('relevance-score' in endPayload({ contentState, now }).aps, false, 'end has no relevance score');
});

test('update payload carries an alert only when given one', () => {
  const alert = { title: 'You took the lead', body: 'x' };
  assert.deepEqual(updatePayload({ contentState, now, alert }).aps.alert, alert);
  assert.equal('alert' in updatePayload({ contentState, now }).aps, false);
});

test('start payload shape', () => {
  const payload = startPayload({ contentState, attributes, now });
  assert.deepEqual(payload, {
    aps: {
      timestamp: 1789934400,
      event: 'start',
      'content-state': contentState,
      'attributes-type': ATTRIBUTES_TYPE,
      attributes,
      alert: { title: 'Sunday Scaries', body: 'Week 2: Gridiron Gurus vs Couch Potatoes' },
      'relevance-score': 100,
      'stale-date': 1789934400 + 30 * 60,
    },
  });
  assert.equal(ATTRIBUTES_TYPE, 'MatchupActivityAttributes');
});

test('end payload shape', () => {
  const payload = endPayload({ contentState, now });
  assert.deepEqual(payload, {
    aps: {
      timestamp: 1789934400,
      event: 'end',
      'content-state': contentState,
      'dismissal-date': 1789934400 + 30 * 60,
    },
  });
});

test('lead change alert only when the lead changes hands', () => {
  const leading = { ...contentState, myPoints: 90, opponentPoints: 80 };
  const trailing = { ...contentState, myPoints: 70, opponentPoints: 80 };
  const tied = { ...contentState, myPoints: 80, opponentPoints: 80 };

  assert.equal(leadChangeAlert({ previousMargin: null, contentState: leading, attributes }), null, 'no history');
  assert.equal(leadChangeAlert({ previousMargin: 5, contentState: leading, attributes }), null, 'still leading');
  assert.equal(leadChangeAlert({ previousMargin: -5, contentState: trailing, attributes }), null, 'still trailing');
  assert.equal(leadChangeAlert({ previousMargin: 0, contentState: trailing, attributes }), null, 'tied → trailing is not a lead change');

  assert.deepEqual(leadChangeAlert({ previousMargin: -5, contentState: leading, attributes }), {
    title: 'You took the lead',
    body: 'Gridiron Gurus 90 - 80 Couch Potatoes',
  });
  assert.deepEqual(leadChangeAlert({ previousMargin: 0, contentState: leading, attributes }), {
    title: 'You took the lead',
    body: 'Gridiron Gurus 90 - 80 Couch Potatoes',
  });
  assert.equal(leadChangeAlert({ previousMargin: 5, contentState: trailing, attributes }).title, 'You lost the lead');
  assert.equal(leadChangeAlert({ previousMargin: 5, contentState: tied, attributes }).title, 'All tied up');
});

test('payloads stay under 4 KB even with long names', () => {
  const long = 'x'.repeat(300);
  const bigAttributes = { ...attributes, leagueName: long, myTeamName: long, opponentTeamName: long, myAvatarId: long, opponentAvatarId: long };
  const start = startPayload({ contentState, attributes: bigAttributes, now });
  const update = updatePayload({
    contentState,
    now,
    alert: leadChangeAlert({ previousMargin: -1, contentState, attributes: bigAttributes }),
  });
  const end = endPayload({ contentState, now });
  for (const payload of [start, update, end]) {
    assert.ok(payloadBytes(payload) < MAX_PAYLOAD_BYTES, `payload is ${payloadBytes(payload)} bytes`);
  }
});

test('formatPoints matches ScoreFormat.points', () => {
  assert.equal(formatPoints(104.3), '104.3');
  assert.equal(formatPoints(104.30000000000001), '104.3');
  assert.equal(formatPoints(104), '104');
  assert.equal(formatPoints(87.42), '87.42');
  assert.equal(formatPoints(0.5), '0.5');
  assert.equal(formatPoints(1.006), '1.01');
  assert.equal(formatPoints(1.005), '1', '1.005 * 100 is 100.49999… in floating point, same as Swift');
});
