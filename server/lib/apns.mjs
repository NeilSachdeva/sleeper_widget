/**
 * Token-based APNs client over HTTP/2 (no dependencies).
 *
 * Auth is an ES256 JWT signed with the .p8 auth key from the Apple Developer
 * portal. Apple accepts a token for at most 60 minutes and asks providers not
 * to mint a new one more than every 20 minutes, so it is cached for 50.
 */

import crypto from 'node:crypto';
import fs from 'node:fs';
import http2 from 'node:http2';

export const HOSTS = {
  production: 'api.push.apple.com',
  development: 'api.sandbox.push.apple.com',
};

export const JWT_REFRESH_MS = 50 * 60 * 1000;
export const REQUEST_TIMEOUT_MS = 15 * 1000;

const TOKEN_DEAD_REASONS = new Set(['BadDeviceToken', 'Unregistered']);
const PROVIDER_TOKEN_REASONS = new Set(['ExpiredProviderToken', 'InvalidProviderToken']);

/**
 * @typedef {object} PushResult
 * @property {number} status HTTP status from APNs
 * @property {object | string} body parsed JSON body when APNs sent one, else raw text
 * @property {string | undefined} apnsId `apns-id` response header
 * @property {string | null} reason APNs error reason (e.g. "BadDeviceToken") when not 2xx
 * @property {boolean} ok 2xx
 * @property {boolean} tokenDead the device token should be discarded
 */

/**
 * Builds the ES256 provider token (JWT) Apple expects in `authorization: bearer`.
 * @param {object} input
 * @param {string | import('node:crypto').KeyObject} input.key PEM contents of the .p8 file
 * @param {string} input.keyId 10-character key id from the developer portal
 * @param {string} input.teamId 10-character team id
 * @param {number} input.issuedAt unix seconds
 * @returns {string}
 */
export function makeProviderToken({ key, keyId, teamId, issuedAt }) {
  const header = base64url(JSON.stringify({ alg: 'ES256', kid: keyId }));
  const claims = base64url(JSON.stringify({ iss: teamId, iat: issuedAt }));
  const signature = crypto
    .sign('sha256', Buffer.from(`${header}.${claims}`), { key, dsaEncoding: 'ieee-p1363' })
    .toString('base64url');
  return `${header}.${claims}.${signature}`;
}

/**
 * 410, or 400 with a token-related reason, means the token will never work again.
 * @param {number} status
 * @param {string | null | undefined} reason
 * @returns {boolean}
 */
export function isTokenDead(status, reason) {
  if (status === 410) return true;
  return status === 400 && TOKEN_DEAD_REASONS.has(reason ?? '');
}

/**
 * @typedef {object} ApnsClient
 * @property {(input: SendInput) => Promise<PushResult>} sendLiveActivityPush
 * @property {() => string} providerToken current (cached) JWT
 * @property {() => void} close closes all HTTP/2 sessions
 */

/**
 * @typedef {object} SendInput
 * @property {string} token hex device / activity token
 * @property {'development' | 'production'} environment picks the APNs host
 * @property {object} payload JSON body (`{ aps: ... }`)
 * @property {number} [priority] 10 for start/end/score changes, 5 for heartbeats
 * @property {number} [expiration] unix seconds; defaults to 30 minutes ahead
 */

/**
 * @param {object} options
 * @param {string} [options.keyPath] path to the .p8 file (or pass `key`)
 * @param {string} [options.key] PEM contents
 * @param {string} options.keyId
 * @param {string} options.teamId
 * @param {string} options.bundleId the app's bundle id (not the widget extension's)
 * @param {() => number} [options.now] millisecond clock, injectable for tests
 * @param {(host: string) => import('node:http2').ClientHttp2Session} [options.connect] injectable for tests
 * @param {{ warn: Function }} [options.log]
 * @returns {ApnsClient}
 */
export function createApnsClient({
  keyPath,
  key = keyPath ? fs.readFileSync(keyPath, 'utf8') : undefined,
  keyId,
  teamId,
  bundleId,
  now = () => Date.now(),
  connect = (host) => http2.connect(`https://${host}:443`),
  log = console,
}) {
  if (!key || !keyId || !teamId || !bundleId) {
    throw new Error('APNs client needs key (or keyPath), keyId, teamId and bundleId');
  }
  const privateKey = crypto.createPrivateKey(key);
  const topic = `${bundleId}.push-type.liveactivity`;

  /** @type {{ token: string, issuedAt: number } | null} */
  let cachedToken = null;
  /** @type {Map<string, import('node:http2').ClientHttp2Session>} */
  const sessions = new Map();

  function providerToken() {
    const nowMs = now();
    if (!cachedToken || nowMs - cachedToken.issuedAt >= JWT_REFRESH_MS) {
      cachedToken = {
        token: makeProviderToken({ key: privateKey, keyId, teamId, issuedAt: Math.floor(nowMs / 1000) }),
        issuedAt: nowMs,
      };
    }
    return cachedToken.token;
  }

  function session(host) {
    const existing = sessions.get(host);
    if (existing && !existing.closed && !existing.destroyed) return existing;

    const fresh = connect(host);
    const drop = () => {
      if (sessions.get(host) === fresh) sessions.delete(host);
    };
    fresh.on('goaway', drop);
    fresh.on('close', drop);
    fresh.on('error', (error) => {
      log.warn(`apns: session to ${host} failed: ${error.message}`);
      drop();
    });
    sessions.set(host, fresh);
    return fresh;
  }

  async function sendOnce({ host, token, payload, priority, expiration }) {
    const headers = {
      ':method': 'POST',
      ':path': `/3/device/${token}`,
      authorization: `bearer ${providerToken()}`,
      'apns-push-type': 'liveactivity',
      'apns-topic': topic,
      'apns-priority': String(priority),
      'apns-expiration': String(expiration),
      'apns-id': crypto.randomUUID(),
      'content-type': 'application/json',
    };
    const raw = await request(session(host), headers, JSON.stringify(payload));
    let body = raw.body;
    let reason = null;
    if (raw.body) {
      try {
        body = JSON.parse(raw.body);
        reason = typeof body?.reason === 'string' ? body.reason : null;
      } catch {
        body = raw.body;
      }
    }
    const ok = raw.status >= 200 && raw.status < 300;
    return { status: raw.status, body, apnsId: raw.apnsId, reason, ok, tokenDead: isTokenDead(raw.status, reason) };
  }

  /** @param {SendInput} input @returns {Promise<PushResult>} */
  async function sendLiveActivityPush({ token, environment, payload, priority = 10, expiration }) {
    const host = HOSTS[environment] ?? HOSTS.development;
    const expires = expiration ?? Math.floor(now() / 1000) + 30 * 60;
    const attempt = () => sendOnce({ host, token, payload, priority, expiration: expires });

    let result = await attempt();
    if (result.status === 403 && PROVIDER_TOKEN_REASONS.has(result.reason ?? '')) {
      cachedToken = null;
      result = await attempt();
    }
    return result;
  }

  function close() {
    for (const s of sessions.values()) s.close();
    sessions.clear();
  }

  return { sendLiveActivityPush, providerToken, close };
}

/** One HTTP/2 request → { status, apnsId, body }. */
function request(session, headers, body) {
  return new Promise((resolve, reject) => {
    const stream = session.request(headers);
    const chunks = [];
    let status = 0;
    let apnsId;
    stream.setEncoding('utf8');
    stream.setTimeout(REQUEST_TIMEOUT_MS, () => {
      stream.close(http2.constants.NGHTTP2_CANCEL);
      reject(new Error('APNs request timed out'));
    });
    stream.on('response', (responseHeaders) => {
      status = Number(responseHeaders[':status']);
      apnsId = responseHeaders['apns-id'];
    });
    stream.on('data', (chunk) => chunks.push(chunk));
    stream.on('end', () => resolve({ status, apnsId, body: chunks.join('') }));
    stream.on('error', reject);
    stream.end(body);
  });
}

function base64url(text) {
  return Buffer.from(text, 'utf8').toString('base64url');
}
