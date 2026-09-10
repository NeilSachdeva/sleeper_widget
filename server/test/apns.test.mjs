import { test } from 'node:test';
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import { EventEmitter } from 'node:events';
import { HOSTS, JWT_REFRESH_MS, createApnsClient, isTokenDead, makeProviderToken } from '../lib/apns.mjs';

const { privateKey, publicKey } = crypto.generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const pem = privateKey.export({ type: 'pkcs8', format: 'pem' });

function decodeSegment(segment) {
  return JSON.parse(Buffer.from(segment, 'base64url').toString('utf8'));
}

test('provider token is an ES256 JWT Apple can verify', () => {
  const jwt = makeProviderToken({ key: pem, keyId: 'ABC123DEFG', teamId: 'TEAMID1234', issuedAt: 1789934400 });
  const [header, claims, signature] = jwt.split('.');
  assert.deepEqual(decodeSegment(header), { alg: 'ES256', kid: 'ABC123DEFG' });
  assert.deepEqual(decodeSegment(claims), { iss: 'TEAMID1234', iat: 1789934400 });
  assert.match(jwt, /^[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/, 'base64url, no padding');
  const verified = crypto.verify(
    'sha256',
    Buffer.from(`${header}.${claims}`),
    { key: publicKey, dsaEncoding: 'ieee-p1363' },
    Buffer.from(signature, 'base64url'),
  );
  assert.equal(verified, true);
  assert.equal(Buffer.from(signature, 'base64url').length, 64, 'raw r||s signature');
});

test('isTokenDead', () => {
  assert.equal(isTokenDead(410, 'Unregistered'), true);
  assert.equal(isTokenDead(410, null), true);
  assert.equal(isTokenDead(400, 'BadDeviceToken'), true);
  assert.equal(isTokenDead(400, 'Unregistered'), true);
  assert.equal(isTokenDead(400, 'BadTopic'), false);
  assert.equal(isTokenDead(403, 'ExpiredProviderToken'), false);
  assert.equal(isTokenDead(200, null), false);
});

/** Fake http2 session: records requests, answers from `respond(headers, body)`. */
function fakeConnect(respond) {
  const sessions = [];
  const connect = (host) => {
    const session = new EventEmitter();
    session.host = host;
    session.closed = false;
    session.destroyed = false;
    session.requests = [];
    session.close = () => {
      session.closed = true;
    };
    session.request = (headers) => {
      const stream = new EventEmitter();
      stream.setEncoding = () => {};
      stream.setTimeout = () => {};
      stream.close = () => {};
      stream.end = (body) => {
        session.requests.push({ headers, body });
        const reply = respond(headers, body);
        process.nextTick(() => {
          stream.emit('response', { ':status': reply.status, 'apns-id': reply.apnsId ?? 'id-1' });
          if (reply.body) stream.emit('data', reply.body);
          stream.emit('end');
        });
      };
      return stream;
    };
    sessions.push(session);
    return session;
  };
  return { connect, sessions };
}

function client(connect, extra = {}) {
  return createApnsClient({
    key: pem, keyId: 'ABC123DEFG', teamId: 'TEAMID1234', bundleId: 'com.sleeperwidget.app', connect, log: { warn() {} }, ...extra,
  });
}

test('sendLiveActivityPush sets the Live Activity headers and picks the host per environment', async () => {
  const { connect, sessions } = fakeConnect(() => ({ status: 200 }));
  const apns = client(connect);
  const payload = { aps: { event: 'update' } };

  const result = await apns.sendLiveActivityPush({ token: 'abc123', environment: 'production', payload, priority: 5, expiration: 1789936200 });
  assert.equal(result.status, 200);
  assert.equal(result.ok, true);
  assert.equal(result.tokenDead, false);
  assert.equal(result.apnsId, 'id-1');

  assert.equal(sessions.length, 1);
  assert.equal(sessions[0].host, HOSTS.production);
  const { headers, body } = sessions[0].requests[0];
  assert.equal(headers[':method'], 'POST');
  assert.equal(headers[':path'], '/3/device/abc123');
  assert.equal(headers['apns-push-type'], 'liveactivity');
  assert.equal(headers['apns-topic'], 'com.sleeperwidget.app.push-type.liveactivity');
  assert.equal(headers['apns-priority'], '5');
  assert.equal(headers['apns-expiration'], '1789936200');
  assert.equal(headers['content-type'], 'application/json');
  assert.match(headers['apns-id'], /^[0-9a-f-]{36}$/);
  assert.match(headers.authorization, /^bearer [A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+$/);
  assert.equal(body, JSON.stringify(payload));

  await apns.sendLiveActivityPush({ token: 'def', environment: 'development', payload });
  assert.equal(sessions.length, 2);
  assert.equal(sessions[1].host, HOSTS.development);
  assert.equal(sessions[1].requests[0].headers['apns-priority'], '10', 'default priority');
  apns.close();
  assert.equal(sessions[0].closed, true);
});

test('dead tokens are flagged from 410 and 400 BadDeviceToken', async () => {
  let reply = { status: 410, body: JSON.stringify({ reason: 'Unregistered', timestamp: 1 }) };
  const { connect } = fakeConnect(() => reply);
  const apns = client(connect);

  let result = await apns.sendLiveActivityPush({ token: 't', environment: 'development', payload: {} });
  assert.equal(result.status, 410);
  assert.equal(result.reason, 'Unregistered');
  assert.equal(result.tokenDead, true);
  assert.deepEqual(result.body, { reason: 'Unregistered', timestamp: 1 });

  reply = { status: 400, body: JSON.stringify({ reason: 'BadDeviceToken' }) };
  result = await apns.sendLiveActivityPush({ token: 't', environment: 'development', payload: {} });
  assert.equal(result.tokenDead, true);

  reply = { status: 400, body: JSON.stringify({ reason: 'BadTopic' }) };
  result = await apns.sendLiveActivityPush({ token: 't', environment: 'development', payload: {} });
  assert.equal(result.tokenDead, false);
  assert.equal(result.ok, false);
});

test('provider token is cached and refreshed after 50 minutes', async () => {
  let clock = 1_789_934_400_000;
  const { connect, sessions } = fakeConnect(() => ({ status: 200 }));
  const apns = client(connect, { now: () => clock });
  const send = () => apns.sendLiveActivityPush({ token: 't', environment: 'development', payload: {} });

  await send();
  clock += 10 * 60 * 1000;
  await send();
  const [first, second] = sessions[0].requests.map((r) => r.headers.authorization);
  assert.equal(first, second, 'same JWT inside the refresh window');

  clock += JWT_REFRESH_MS;
  await send();
  const third = sessions[0].requests[2].headers.authorization;
  assert.notEqual(third, first, 'new JWT after 50 minutes');
  assert.equal(decodeSegment(third.split(' ')[1].split('.')[1]).iat, Math.floor(clock / 1000));
});

test('an expired provider token is minted again and the push retried once', async () => {
  let calls = 0;
  const { connect, sessions } = fakeConnect(() => {
    calls += 1;
    return calls === 1 ? { status: 403, body: JSON.stringify({ reason: 'ExpiredProviderToken' }) } : { status: 200 };
  });
  const apns = client(connect);
  const result = await apns.sendLiveActivityPush({ token: 't', environment: 'development', payload: {} });
  assert.equal(result.status, 200);
  assert.equal(sessions[0].requests.length, 2);
});

test('a session that went away is replaced on the next push', async () => {
  const { connect, sessions } = fakeConnect(() => ({ status: 200 }));
  const apns = client(connect);
  await apns.sendLiveActivityPush({ token: 't', environment: 'development', payload: {} });
  sessions[0].emit('goaway');
  await apns.sendLiveActivityPush({ token: 't', environment: 'development', payload: {} });
  assert.equal(sessions.length, 2);
});
