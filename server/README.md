# Sleeper Widget push relay

Optional Node.js server that starts and updates the app's matchup Live Activity
through APNs while NFL games are on, so the activity appears on the Lock Screen
even when the app is closed. Without it, the app still refreshes the activity in
the foreground and in background refresh slots; the relay just makes it
continuous.

Node 20+ (22 recommended), **zero npm dependencies** — only `node:http`,
`node:http2`, `node:crypto`, `node:fs` and the global `fetch`.

## How it works

Every `POLL_INTERVAL_SECONDS` (default 60) the relay:

1. Reads `GET /v1/state/nfl` from Sleeper for the current week, then fetches each
   registered league once (league, rosters, users, matchups) and builds the same
   `MatchupSnapshot` the app builds (`lib/matchup.mjs` mirrors
   `Shared/MatchupService.swift`; `lib/gameWindow.mjs` mirrors `Shared/GameWindow.swift`).
2. For a registration **with a running activity** (`activityToken`): sends an
   `update` when the scores/records/phase changed, a low-priority heartbeat every
   20 minutes inside a game window (keeps `stale-date` moving), or an `end` once
   the game window is over and the week is no longer live (or the matchup is final).
   If the user started the activity by hand (`startedManually: true` in the
   registration) the relay mirrors the app's `reconcile`: it only ends the
   activity when the matchup is `final`, and keeps the 20-minute heartbeat going
   outside game windows too.
3. For a registration **without** a running activity but with a
   `pushToStartToken`: sends a push-to-start inside a game window (Thu night,
   Sun, Mon night, plus Sat from week 15), unless it is a bye week or a start was
   already sent for that league and week in the last 30 minutes.
4. Clears any token APNs reports as dead (`410`, or `400 BadDeviceToken` /
   `Unregistered`). At most one push per registration per tick.

An update gets an alert (`aps.alert`) only when the lead changes hands, so users
are not buzzed on every score change.

## Setup

### 1. Create an APNs auth key

In the [Apple Developer portal](https://developer.apple.com/account/resources/authkeys/list):
**Keys › + › enable "Apple Push Notifications service (APNs)"**. Download the
`AuthKey_<KEY_ID>.p8` file (you can only download it once) and note the **Key ID**
and your **Team ID** (top right of the portal). One key works for both the
sandbox and production APNs hosts and for every app on the team.

### 2. Configure

```sh
cd server
cp .env.example .env   # then edit
```

| Variable | Default | Meaning |
| --- | --- | --- |
| `PORT` | `8787` | HTTP port the app registers with |
| `APNS_KEY_PATH` | — | Path to the `.p8` file |
| `APNS_KEY_ID` | — | Key ID from the portal |
| `APNS_TEAM_ID` | — | Your Team ID |
| `APNS_BUNDLE_ID` | `com.sleeperwidget.app` | The **app** bundle id (`PRODUCT_BUNDLE_IDENTIFIER` of the `SleeperWidget` target in `project.yml`), not the widget extension's. APNs topic = `<bundle id>.push-type.liveactivity` |
| `POLL_INTERVAL_SECONDS` | `60` | Sleeper poll / push cadence |
| `STORE_PATH` | `./registrations.json` | Where registrations are persisted (atomic JSON file) |
| `RELAY_AUTH_TOKEN` | unset | Optional. Requires `Authorization: Bearer <token>` on the registration routes. **The iOS `RelayClient` does not send this header today**, so only set it on a private deployment after adding the header in `Shared/RelayClient.swift`. |

`.env` is loaded if present (simple `KEY=value` lines; real environment variables win).
If the three `APNS_*` credentials are missing the server still starts and accepts
registrations, logs a warning, and sends nothing — handy while setting things up.

### 3. Run

```sh
npm start      # node index.mjs
npm test       # node --test (no network needed)
```

```
GET    /healthz                        → 200 {"ok":true,"registrations":N}
PUT    /v1/registrations/<installId>   JSON body = RelayClient.Registration → 204
DELETE /v1/registrations/<installId>   → 204
```

### 4. Deploy

Anything that runs Node and keeps a small file on disk works: a VPS with
`systemd`/`pm2`, a container, Fly.io (`fly launch` in `server/`, add a volume
for `STORE_PATH`), Railway, Render, etc. Put it behind HTTPS — iOS App Transport
Security blocks plain `http://` relay URLs unless you add an ATS exception.
Copy the `.p8` to the host (or paste it into a secret and write it to a file at
boot) and set the env vars there instead of shipping `.env`.

### 5. Point the app at it

In the app: **Settings › Push relay (optional)**, enter the relay's base URL
(e.g. `https://relay.example.com`) and tap **Save relay URL**. The app then
`PUT`s a registration containing the Sleeper user id, league id, APNs
environment (`development` for Debug builds, `production` otherwise) and the
push tokens it has:

- `pushToStartToken` — from `Activity.pushToStartTokenUpdates`; lets the relay
  start the activity remotely. **Requires iOS 17.2+**.
- `activityToken` / `activityId` — the update token for the currently running
  activity, from `activity.pushTokenUpdates`.
- `startedManually` — optional boolean (default `false`); `true` when the user
  started the activity from the app rather than automatically.

The app re-registers whenever a token changes, and `DELETE`s its row when the
relay URL is cleared or the user signs out.

**Push-to-start flow:** after the relay sends a `start`, iOS creates the activity
and wakes the app briefly in the background; the app adopts the new activity and
registers its `activityToken` with the relay. Updates only flow after that
registration lands, so the first score update can trail the start by a minute or
so (one poll interval after the token arrives). If the app is force-quit
push-to-start still works, but the background wake for token registration is
at iOS's discretion.

## Apple budget caveats

- A Live Activity push payload must stay under **4 KB** (tests assert this with
  long team names).
- iOS throttles frequent updates. The app sets
  `NSSupportsLiveActivitiesFrequentUpdates` in its Info.plist, which raises the
  budget, but users can turn frequent updates off per app in Settings. The relay
  only sends when something changed (plus a 20-minute heartbeat), so normal
  traffic is well within limits.
- Score changes, starts and ends use `apns-priority: 10`; heartbeats use `5`.
  `apns-expiration` is 30 minutes ahead so stale pushes are dropped rather than
  delivered late. `relevance-score` matches the app: 100 inside a game window,
  50 otherwise.
- iOS ends a Live Activity on its own after 8 hours on the Lock Screen (12 hours
  in total), regardless of pushes.
- Provider JWTs are cached for 50 minutes (Apple: valid for at most 60, refresh
  no more often than every 20). Each APNs host gets one HTTP/2 connection that is
  reconnected after `GOAWAY` or an error.

## Layout

```
index.mjs          entry point: .env, HTTP server, poll loop
lib/http.mjs       routes + registration validation
lib/relay.mjs      the per-tick decision loop
lib/apns.mjs       ES256 JWT + HTTP/2 client for APNs
lib/payloads.mjs   start / update / end payload builders (match the Swift types)
lib/matchup.mjs    MatchupBuilder port + content-state / attributes projections
lib/gameWindow.mjs GameWindow port (America/New_York, DST-safe, no libraries)
lib/sleeper.mjs    Sleeper API client with a small in-memory cache
lib/store.mjs      JSON-file registration store (atomic writes)
test/              node:test suites; run with `npm test`
```
