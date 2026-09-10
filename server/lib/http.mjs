/**
 * HTTP API the iOS app talks to (see Shared/RelayClient.swift):
 *
 *   GET    /healthz                        → 200 { ok: true, registrations: N }
 *   PUT    /v1/registrations/<installId>   JSON body = Registration → 204
 *   DELETE /v1/registrations/<installId>   → 204
 *
 * Bodies are capped at 16 KB. When `authToken` is set, the registration routes
 * require `Authorization: Bearer <token>`.
 */

import http from 'node:http';

export const BODY_LIMIT_BYTES = 16 * 1024;
const ENVIRONMENTS = new Set(['development', 'production']);
const HEX = /^[0-9a-f]+$/i;
const REGISTRATION_PATH = /^\/v1\/registrations\/([^/]+)$/;

/**
 * Checks a registration body against the Swift `RelayClient.Registration` shape.
 * @param {unknown} body parsed JSON
 * @param {string} installId from the URL; must match the body
 * @returns {{ registration: object } | { error: string }}
 */
export function validateRegistration(body, installId) {
  if (!body || typeof body !== 'object' || Array.isArray(body)) return { error: 'body must be a JSON object' };

  for (const field of ['installId', 'userId', 'leagueId', 'environment']) {
    if (typeof body[field] !== 'string' || body[field].trim() === '') return { error: `${field} is required` };
  }
  if (body.installId !== installId) return { error: 'installId in body does not match the URL' };
  if (!ENVIRONMENTS.has(body.environment)) return { error: 'environment must be "development" or "production"' };
  if (body.startedManually !== undefined && body.startedManually !== null && typeof body.startedManually !== 'boolean') {
    return { error: 'startedManually must be a boolean' };
  }

  const registration = {
    installId: body.installId,
    userId: body.userId,
    leagueId: body.leagueId,
    environment: body.environment,
    timeZone: optionalString(body.timeZone),
    activityId: optionalString(body.activityId),
    pushToStartToken: optionalString(body.pushToStartToken),
    activityToken: optionalString(body.activityToken),
    startedManually: body.startedManually === true,
  };
  for (const field of ['pushToStartToken', 'activityToken']) {
    const value = registration[field];
    if (value !== null && !HEX.test(value)) return { error: `${field} must be a hex string` };
  }
  return { registration };
}

/**
 * @param {object} options
 * @param {import('./store.mjs').Store} options.store
 * @param {string | null} [options.authToken]
 * @param {{ info: Function, warn: Function, error: Function }} [options.log]
 * @returns {import('node:http').Server}
 */
export function createRelayServer({ store, authToken = null, log = console }) {
  async function handle(request, response) {
    const url = new URL(request.url ?? '/', 'http://relay.local');

    if (request.method === 'GET' && url.pathname === '/healthz') {
      return sendJson(response, 200, { ok: true, registrations: store.size() });
    }

    const match = REGISTRATION_PATH.exec(url.pathname);
    if (!match) return sendJson(response, 404, { error: 'not found' });

    if (authToken && request.headers.authorization !== `Bearer ${authToken}`) {
      return sendJson(response, 401, { error: 'unauthorized' });
    }

    let installId;
    try {
      installId = decodeURIComponent(match[1]);
    } catch {
      return sendJson(response, 400, { error: 'bad installId' });
    }

    if (request.method === 'PUT') {
      let body;
      try {
        body = JSON.parse(await readBody(request, BODY_LIMIT_BYTES));
      } catch (error) {
        if (error?.code === 'BODY_TOO_LARGE') {
          response.setHeader('connection', 'close');
          return sendJson(response, 413, { error: 'body too large' });
        }
        return sendJson(response, 400, { error: 'invalid JSON' });
      }
      const checked = validateRegistration(body, installId);
      if ('error' in checked) return sendJson(response, 400, { error: checked.error });
      const row = store.put(checked.registration);
      log.info(
        `registered install=${row.installId} league=${row.leagueId} env=${row.environment} ` +
          `pushToStart=${row.pushToStartToken ? 'yes' : 'no'} activity=${row.activityToken ? 'yes' : 'no'}`,
      );
      return sendEmpty(response, 204);
    }

    if (request.method === 'DELETE') {
      if (store.remove(installId)) log.info(`unregistered install=${installId}`);
      return sendEmpty(response, 204);
    }

    return sendJson(response, 404, { error: 'not found' });
  }

  return http.createServer((request, response) => {
    handle(request, response).catch((error) => {
      log.error(`http: ${request.method} ${request.url}: ${error.stack ?? error.message}`);
      if (!response.headersSent) sendJson(response, 500, { error: 'internal error' });
      else response.end();
    });
  });
}

function optionalString(value) {
  return typeof value === 'string' && value !== '' ? value : null;
}

function readBody(request, limit) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    let overflowed = false;
    request.on('data', (chunk) => {
      if (overflowed) return; // keep draining so the 413 can be delivered
      size += chunk.length;
      if (size > limit) {
        overflowed = true;
        chunks.length = 0;
        const error = new Error('body too large');
        error.code = 'BODY_TOO_LARGE';
        reject(error);
        return;
      }
      chunks.push(chunk);
    });
    request.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    request.on('error', reject);
  });
}

function sendJson(response, status, body) {
  const text = JSON.stringify(body);
  response.writeHead(status, { 'content-type': 'application/json', 'content-length': Buffer.byteLength(text) });
  response.end(text);
}

function sendEmpty(response, status) {
  response.writeHead(status);
  response.end();
}
