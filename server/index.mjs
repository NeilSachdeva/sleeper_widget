/**
 * Entry point: loads `.env`, starts the HTTP API the app registers with, and
 * runs the poll loop that pushes Live Activity starts/updates/ends via APNs.
 */

import fs from 'node:fs';
import path from 'node:path';
import { createApnsClient } from './lib/apns.mjs';
import { createRelayServer } from './lib/http.mjs';
import { tick } from './lib/relay.mjs';
import { createSleeperClient } from './lib/sleeper.mjs';
import { createStore } from './lib/store.mjs';

loadDotEnv(path.resolve('.env'));

const config = {
  port: Number(process.env.PORT ?? 8787),
  apnsKeyPath: process.env.APNS_KEY_PATH ?? '',
  apnsKeyId: process.env.APNS_KEY_ID ?? '',
  apnsTeamId: process.env.APNS_TEAM_ID ?? '',
  apnsBundleId: process.env.APNS_BUNDLE_ID ?? 'com.sleeperwidget.app',
  pollIntervalSeconds: Number(process.env.POLL_INTERVAL_SECONDS ?? 60),
  storePath: path.resolve(process.env.STORE_PATH ?? './registrations.json'),
  authToken: process.env.RELAY_AUTH_TOKEN || null,
};

const log = createLogger();
const store = createStore({ path: config.storePath });
store.load();
log.info(`loaded ${store.size()} registration(s) from ${config.storePath}`);

const apns = createApnsOrNull(config, log);
const sleeper = createSleeperClient();

const server = createRelayServer({ store, authToken: config.authToken, log });
server.listen(config.port, () => {
  log.info(`listening on http://0.0.0.0:${config.port} (auth ${config.authToken ? 'required' : 'off'})`);
});

if (apns) {
  let running = false;
  const runTick = async () => {
    if (running) return; // a slow tick must not overlap the next one
    running = true;
    try {
      const summary = await tick({ store, sleeper, apns, now: new Date(), log });
      log.info(`tick: registrations=${summary.registrations} pushes=${summary.pushes} errors=${summary.errors}`);
    } catch (error) {
      log.error(`tick failed: ${error.stack ?? error.message}`);
    } finally {
      running = false;
    }
  };
  runTick();
  setInterval(runTick, Math.max(10, config.pollIntervalSeconds) * 1000);
} else {
  log.warn(
    'APNs is not configured (need APNS_KEY_PATH, APNS_KEY_ID and APNS_TEAM_ID). ' +
      'Registrations are accepted and stored, but no pushes will be sent until the server is restarted with them set.',
  );
}

for (const signal of ['SIGINT', 'SIGTERM']) {
  process.on(signal, () => {
    log.info(`${signal} received, shutting down`);
    server.close();
    apns?.close();
    process.exit(0);
  });
}

// MARK: - Helpers

function createApnsOrNull(cfg, logger) {
  if (!cfg.apnsKeyPath || !cfg.apnsKeyId || !cfg.apnsTeamId) return null;
  try {
    const client = createApnsClient({
      keyPath: path.resolve(cfg.apnsKeyPath),
      keyId: cfg.apnsKeyId,
      teamId: cfg.apnsTeamId,
      bundleId: cfg.apnsBundleId,
      log: logger,
    });
    logger.info(`APNs ready: key ${cfg.apnsKeyId}, team ${cfg.apnsTeamId}, topic ${cfg.apnsBundleId}.push-type.liveactivity`);
    return client;
  } catch (error) {
    logger.error(`APNs setup failed (${error.message}); pushes are disabled`);
    return null;
  }
}

/** Minimal `.env` loader: KEY=value lines, `#` comments, optional quotes; never overrides the real environment. */
function loadDotEnv(filePath) {
  if (!fs.existsSync(filePath)) return;
  for (const rawLine of fs.readFileSync(filePath, 'utf8').split(/\r?\n/)) {
    const line = rawLine.trim();
    if (line === '' || line.startsWith('#')) continue;
    const separator = line.indexOf('=');
    if (separator < 1) continue;
    const key = line.slice(0, separator).trim();
    let value = line.slice(separator + 1).trim();
    const quoted = value.length >= 2 && (value[0] === '"' || value[0] === "'") && value.at(-1) === value[0];
    if (quoted) value = value.slice(1, -1);
    if (!(key in process.env)) process.env[key] = value;
  }
}

function createLogger() {
  const line = (level, message) => `${new Date().toISOString()} ${level} ${message}`;
  return {
    info: (message) => console.log(line('INFO', message)),
    warn: (message) => console.warn(line('WARN', message)),
    error: (message) => console.error(line('ERROR', message)),
  };
}
