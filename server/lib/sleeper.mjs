/**
 * Thin client for Sleeper's public, unauthenticated read API (mirrors
 * Shared/SleeperAPI.swift). Responses are returned as raw snake_case JSON.
 *
 * Stay under ~1000 calls/minute per Sleeper's guidance: the relay makes four
 * calls per league per tick plus one `state` call, and caches the slow-moving
 * ones so many registrations in one league cost about the same as one.
 */

export const DEFAULT_BASE_URL = 'https://api.sleeper.app/v1';
export const STATE_TTL_MS = 60 * 1000;
export const LEAGUE_TTL_MS = 10 * 60 * 1000;

export class SleeperError extends Error {
  /**
   * @param {string} message
   * @param {{ status?: number | null, notFound?: boolean }} [details]
   */
  constructor(message, { status = null, notFound = false } = {}) {
    super(message);
    this.name = 'SleeperError';
    this.status = status;
    this.notFound = notFound;
  }
}

/**
 * @typedef {object} SleeperClient
 * @property {(sport?: string) => Promise<object>} state `GET /state/<sport>` (cached 60 s)
 * @property {(leagueId: string) => Promise<object>} league `GET /league/<id>` (cached 10 min)
 * @property {(leagueId: string) => Promise<object[]>} rosters `GET /league/<id>/rosters` (cached 10 min)
 * @property {(leagueId: string) => Promise<object[]>} users `GET /league/<id>/users` (cached 10 min)
 * @property {(leagueId: string, week: number) => Promise<object[]>} matchups `GET /league/<id>/matchups/<week>` (not cached)
 * @property {() => void} clearCache
 */

/**
 * @param {object} [options]
 * @param {string} [options.baseUrl]
 * @param {typeof fetch} [options.fetch] injectable for tests
 * @param {number} [options.timeoutMs]
 * @param {() => number} [options.now] millisecond clock, injectable for tests
 * @returns {SleeperClient}
 */
export function createSleeperClient({
  baseUrl = DEFAULT_BASE_URL,
  fetch = globalThis.fetch,
  timeoutMs = 15_000,
  now = () => Date.now(),
} = {}) {
  /** @type {Map<string, { promise: Promise<any>, expires: number }>} */
  const cache = new Map();

  async function get(path) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetch(`${baseUrl}/${path}`, {
        signal: controller.signal,
        headers: { accept: 'application/json' },
      });
      if (response.status === 404) {
        throw new SleeperError(`Not found on Sleeper: ${path}`, { status: 404, notFound: true });
      }
      if (!response.ok) {
        throw new SleeperError(`Sleeper returned HTTP ${response.status} for ${path}`, { status: response.status });
      }
      const text = await response.text();
      // Sleeper answers some lookups (unknown user, empty week) with a bare `null`.
      const trimmed = text.trim();
      if (trimmed === '' || trimmed.startsWith('null')) {
        throw new SleeperError(`Sleeper has no data for ${path}`, { status: response.status, notFound: true });
      }
      return JSON.parse(text);
    } catch (error) {
      if (error?.name === 'AbortError') {
        throw new SleeperError(`Sleeper request timed out after ${timeoutMs} ms: ${path}`);
      }
      throw error;
    } finally {
      clearTimeout(timer);
    }
  }

  /** Caches the in-flight promise too, so concurrent callers share one request. */
  function cached(path, ttlMs) {
    const hit = cache.get(path);
    if (hit && hit.expires > now()) return hit.promise;
    const promise = get(path);
    cache.set(path, { promise, expires: now() + ttlMs });
    promise.catch(() => {
      if (cache.get(path)?.promise === promise) cache.delete(path);
    });
    return promise;
  }

  return {
    state: (sport = 'nfl') => cached(`state/${sport}`, STATE_TTL_MS),
    league: (leagueId) => cached(`league/${leagueId}`, LEAGUE_TTL_MS),
    rosters: (leagueId) => cached(`league/${leagueId}/rosters`, LEAGUE_TTL_MS),
    users: (leagueId) => cached(`league/${leagueId}/users`, LEAGUE_TTL_MS),
    matchups: (leagueId, week) => get(`league/${leagueId}/matchups/${week}`),
    clearCache: () => cache.clear(),
  };
}
