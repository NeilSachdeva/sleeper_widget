/**
 * JSON-file store of registrations keyed by installId.
 *
 * Client fields match `RelayClient.Registration` in Shared/RelayClient.swift;
 * the rest is server-side bookkeeping used by the relay loop. Writes go to a
 * temp file and are renamed into place so a crash never leaves a torn file.
 */

import fs from 'node:fs';
import path from 'node:path';

/**
 * @typedef {object} Registration
 * @property {string} installId
 * @property {string} userId
 * @property {string} leagueId
 * @property {string | null} pushToStartToken hex, from `Activity.pushToStartTokenUpdates`
 * @property {string | null} activityToken hex, for the running activity
 * @property {string | null} activityId
 * @property {'development' | 'production'} environment
 * @property {string | null} timeZone
 * @property {boolean} startedManually the user started the activity by hand; only `final` ends it
 * @property {string | null} suppressAutoStartUntil ISO time; no push-to-start before it (the user tapped Stop)
 * @property {string | null} lastContentStateHash hash of the last content-state pushed to `activityToken`
 * @property {string | null} lastPushAt ISO time of the last update pushed to `activityToken`
 * @property {string | null} lastStartPushAt ISO time of the last push-to-start
 * @property {string | null} lastStartKey `<leagueId>:<week>` the last push-to-start was for
 * @property {'pregame' | 'live' | 'final' | null} lastPhase
 * @property {number | null} lastMargin my points minus opponent points at the last push
 * @property {string} updatedAt ISO time of the last change to this row
 */

const CLIENT_FIELDS = ['installId', 'userId', 'leagueId', 'pushToStartToken', 'activityToken', 'activityId', 'environment', 'timeZone', 'suppressAutoStartUntil'];
const FLAG_FIELDS = ['startedManually'];
const BOOKKEEPING_FIELDS = ['lastContentStateHash', 'lastPushAt', 'lastStartPushAt', 'lastStartKey', 'lastPhase', 'lastMargin'];

/**
 * @typedef {object} Store
 * @property {() => void} load reads the file (missing file = empty store)
 * @property {() => Registration[]} all
 * @property {(installId: string) => Registration | null} get
 * @property {(registration: object) => Registration} put replaces client fields, keeps bookkeeping
 * @property {(installId: string, fields: Partial<Registration>) => Registration | null} patch merges fields
 * @property {(installId: string) => boolean} remove
 * @property {() => number} size
 */

/**
 * @param {object} options
 * @param {string} options.path file to persist to
 * @param {() => Date} [options.now]
 * @returns {Store}
 */
export function createStore({ path: filePath, now = () => new Date() }) {
  /** @type {Map<string, Registration>} */
  let rows = new Map();

  function load() {
    if (!fs.existsSync(filePath)) {
      rows = new Map();
      return;
    }
    const parsed = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    const list = Array.isArray(parsed) ? parsed : Object.values(parsed ?? {});
    rows = new Map(list.map((row) => [row.installId, row]));
  }

  function save() {
    const directory = path.dirname(filePath);
    fs.mkdirSync(directory, { recursive: true });
    const temp = path.join(directory, `.${path.basename(filePath)}.${process.pid}.${Date.now()}.tmp`);
    fs.writeFileSync(temp, JSON.stringify([...rows.values()], null, 2));
    fs.renameSync(temp, filePath);
  }

  function put(registration) {
    const existing = rows.get(registration.installId);
    const row = {};
    for (const field of CLIENT_FIELDS) row[field] = registration[field] ?? null;
    for (const field of FLAG_FIELDS) row[field] = registration[field] === true;
    for (const field of BOOKKEEPING_FIELDS) row[field] = existing?.[field] ?? null;
    // A different activity token means a new activity: what we sent before no longer applies.
    if (existing && existing.activityToken !== row.activityToken) {
      row.lastContentStateHash = null;
      row.lastPushAt = null;
    }
    row.updatedAt = now().toISOString();
    rows.set(row.installId, row);
    save();
    return row;
  }

  function patch(installId, fields) {
    const existing = rows.get(installId);
    if (!existing) return null;
    const row = { ...existing, ...fields, updatedAt: now().toISOString() };
    rows.set(installId, row);
    save();
    return row;
  }

  function remove(installId) {
    const removed = rows.delete(installId);
    if (removed) save();
    return removed;
  }

  return {
    load,
    all: () => [...rows.values()],
    get: (installId) => rows.get(installId) ?? null,
    put,
    patch,
    remove,
    size: () => rows.size,
  };
}
