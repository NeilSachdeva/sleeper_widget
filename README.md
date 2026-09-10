# Sleeper Widget

An iPhone Live Activity for your [Sleeper](https://sleeper.com) fantasy football matchup.
While games are on, your score vs. your opponent's sits on the Lock Screen next to your
notifications and in the Dynamic Island, and updates as points come in. It also ships
Lock Screen and Home Screen widgets for a quick glance any time.

| Surface | What you see |
| --- | --- |
| Lock Screen Live Activity | Both teams, scores, records, lead margin, week, live/final state |
| Dynamic Island | Compact: your score / their score. Expanded: full scoreboard. Minimal: margin |
| Lock Screen widgets | Rectangular scoreboard, inline "87.4–74.1 · +13.3", circular score pair |
| Home Screen widgets | Small and medium scoreboard cards |

No Sleeper password is needed: the app uses Sleeper's public read-only API with your username.

Mockups of every surface are in [`docs/mockups/`](docs/mockups/README.md).

### No paid developer membership yet?

A free Personal Team can still run the Live Activity on your own phone. Generate the
project from the personal spec instead, which drops the App Groups and Push
Notifications capabilities Apple doesn't allow on personal teams:

```sh
xcodegen generate --spec project-personal.yml
```

What changes: the Home and Lock Screen widgets can't read the app's data (they say
"Open the app"), the push relay is disabled, and the build expires after 7 days. The
Live Activity, the Dynamic Island, the in-activity refresh button, and foreground
refresh all work as normal. Switch back to `xcodegen generate` once you have a paid team.

## How it works

- **Sign in** with your Sleeper username and pick a league. The app finds your roster and
  this week's opponent, then saves a `MatchupSnapshot` to an App Group so the widgets can
  read it.
- **The Live Activity starts on its own** when you open the app during an NFL game window
  (Thursday night, Sunday, Monday night, plus Saturdays late in the season). You can also
  pin it manually any time from the matchup screen.
- **Scores refresh** every 45 seconds while the app is open, opportunistically in the
  background via `BGAppRefreshTask`, and each time the widget timeline reloads.
- **Fully automatic mode (optional):** run the relay in [`server/`](server/README.md). The
  app registers its ActivityKit push tokens with the relay, which polls Sleeper and sends
  APNs Live Activity pushes: push-to-start when kickoff arrives, updates as scores change,
  and an end push after Monday night. This is what makes the activity "pop up when relevant"
  even if the app hasn't been opened.

## Project layout

```
project.yml                 XcodeGen spec (app + widget extension + tests)
Shared/                     Compiled into both the app and the extension
  AppConfig.swift           App Group id, task ids, URL scheme
  SleeperModels.swift       Codable models for Sleeper's API
  SleeperAPI.swift          Async client for api.sleeper.app
  MatchupService.swift      Fetches + builds a MatchupSnapshot (pure builder is unit-tested)
  MatchupSnapshot.swift     The one struct every surface renders
  MatchupActivityAttributes.swift  ActivityKit contract (attributes + ContentState)
  GameWindow.swift          NFL game windows in US Eastern time
  SharedStore.swift         App Group UserDefaults
  AvatarCache.swift         Caches avatars in the App Group for widgets/Live Activity
  AvatarView.swift          Avatar or initials
  RelayClient.swift         Registers push tokens with server/
SleeperWidget/              The app
  SleeperWidgetApp.swift    Scene phases, background task registration
  Services/AppModel.swift   Sign-in, league selection, refresh loop
  Services/LiveActivityManager.swift  Start/update/end + token observation
  Services/BackgroundRefresh.swift    BGAppRefreshTask scheduling and handler
  Views/                    Sign in → league picker → matchup + settings
SleeperWidgetExtension/     WidgetKit extension
  MatchupLiveActivity.swift Lock Screen banner + Dynamic Island
  MatchupWidget.swift       Accessory + system widget families and timeline provider
SleeperWidgetTests/         XCTest: builder, game windows, decoding
server/                     Optional Node.js APNs push relay (no dependencies)
```

## Building

Requirements: Xcode 16 or newer, iOS 17.2+ device (Live Activities and the Dynamic Island
do not fully work in the simulator; push-to-start needs a real device), and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

1. Pick your identifiers. In `project.yml` change `bundleIdPrefix`, the three
   `PRODUCT_BUNDLE_IDENTIFIER`s, `BGTaskSchedulerPermittedIdentifiers`, and the
   App Group (`group.com.sleeperwidget.shared`). Update the same App Group and task id in
   `Shared/AppConfig.swift`. The extension's bundle id must be prefixed by the app's.
   The app ships as "Matchup Live" (`AppConfig.displayName` and `CFBundleDisplayName`);
   rename it there if you like. If you deploy the relay, set `AppConfig.defaultRelayURL`
   so testers get cloud updates without touching Settings.
2. Generate and open the project:

   ```sh
   xcodegen generate
   open SleeperWidget.xcodeproj
   ```

3. In Xcode, set your Team on the `SleeperWidget` and `SleeperWidgetExtension` targets.
   Automatic signing registers the App Group and Push Notifications capabilities the
   first time you build.
4. Run on your iPhone. Sign in with your Sleeper username, choose a league, and tap
   **Show on Lock Screen** (or wait for a game window).
5. Add the Lock Screen widget: long-press the Lock Screen → Customize → tap the widget
   area → **Fantasy Matchup**.

Run the unit tests with ⌘U or:

```sh
xcodebuild test -scheme SleeperWidget -destination 'platform=iOS Simulator,name=iPhone 16'
```

## Live Activity lifecycle and limits

- iOS keeps a Live Activity for at most 8 hours; it then lingers on the Lock Screen for up
  to 4 more hours. Sunday's slate is longer than that, so the app (or relay) starts a fresh
  activity when needed. The relay's push-to-start handles this without opening the app.
- An activity started automatically ends after its game window; one you pinned manually
  stays until the week's games are over or you stop it.
- If a state hasn't been refreshed for 30 minutes the system shows it as stale
  ("Scores may be out of date"). The relay's heartbeat updates keep it fresh.
- Live Activities and widgets cannot load images from the network, so avatars are cached
  into the App Group by the app; until then you'll see team initials.
- Sleeper's API has no live game clock, so "Live" means the week's games are underway
  (Thursday kickoff through Monday night) and "Final" means points are in and the week is
  over. Game windows are approximations of the NFL schedule in US Eastern time
  (`Shared/GameWindow.swift`), which you can adjust.

## Testing on a device

- **Live Activity UI:** the `#Preview` blocks in `MatchupLiveActivity.swift` and
  `MatchupWidget.swift` render every presentation in Xcode's canvas with sample data.
- **Refresh button:** the arrow on the Lock Screen banner and in the expanded Dynamic
  Island runs `RefreshMatchupIntent` in the app's process without opening the app.
- **Background refresh:** the Simulator never runs `BGAppRefreshTask`. On a device, pause
  in the debugger after the app goes to the background and run:

  ```
  e -l objc -- (void)[[BGTaskScheduler sharedScheduler] _simulateLaunchForTaskWithIdentifier:@"com.sleeperwidget.refresh"]
  ```

- **Push updates without the relay:** copy the activity token from Settings › Diagnostics
  and send a payload straight to APNs (sandbox host for Xcode builds). The Simulator
  receives real APNs pushes on Apple silicon Macs:

  ```
  curl --http2 \
    --header "apns-topic: com.sleeperwidget.app.push-type.liveactivity" \
    --header "apns-push-type: liveactivity" \
    --header "apns-priority: 10" \
    --header "authorization: bearer $APNS_JWT" \
    --data '{"aps":{"timestamp":'$(date +%s)',"event":"update","content-state":{"myPoints":91.4,"opponentPoints":80.2,"myRecord":"1-0","opponentRecord":"0-1","phase":"live","updatedAtUnix":'$(date +%s)'}}}' \
    https://api.sandbox.push.apple.com/3/device/$ACTIVITY_PUSH_TOKEN
  ```

## Push relay (optional)

See [`server/README.md`](server/README.md). In short: create an APNs auth key, set four
environment variables, run `npm start`, then paste the relay URL (and the bearer token, if
you started the relay with `RELAY_AUTH_TOKEN`) into the app's Settings.

Once the relay has accepted a registration, the app runs in **relay-first mode**: it
schedules no background refreshes of its own, because the relay already polls Sleeper and
pushes every change. If the relay stops accepting registrations for a day, background
refresh resumes on its own. Tapping **Stop** in the app also tells the relay not to
push-to-start again until the current game window is over. The app sends the
relay its push-to-start token and, once an activity is running, that activity's update
token, plus whether you pinned the activity by hand so the relay knows not to end it
between game windows.

## Notes on the API

Everything comes from Sleeper's public endpoints under `https://api.sleeper.app/v1`:
`user`, `user/{id}/leagues/nfl/{season}`, `league/{id}`, `league/{id}/rosters`,
`league/{id}/users`, `league/{id}/matchups/{week}`, and `state/nfl`. Avatars come from
`https://sleepercdn.com/avatars/thumbs/{avatar_id}`. Stay well under 1,000 calls per
minute; a refresh here is five calls.
