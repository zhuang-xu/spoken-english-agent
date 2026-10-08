# iOS client

Phase 4 is complete at the simulator gate. Phase 5 local build and tests pass;
hosted and physical-device verification remain open. The checked-in `SpokenAgents.xcodeproj`
has an iPhone SwiftUI app, unit tests, UI tests, a shared scheme, and the pinned
native WebRTC package. Its call coordinator, backend client, SDP exchange,
permission flow, manual-turn event handling, and WAV recorder are exercised with
fakes. The foreground practice loop validates setup, shows transcript parts,
sends heartbeats, and handles cancellation and audio interruptions. A SwiftData
store keeps sessions, transcript parts, protected turn audio, an immutable
upload journal, final manifests, and full cached reports. Finishing a practice
retries uploads, declares every intended component, checks readiness, and requests
coaching with bounded progress polling. History opens the full report offline,
retries saving or assessment, and refreshes an existing report without losing its
cached copy. Native sign-in now uses MSAL and a delegated Spoken Agents API scope.
The app verifies `/me` before selecting an account's SwiftData partition. The
legacy `local` partition remains hidden. A cached MSAL account can reopen its
previously verified history offline; sign-out hides it immediately. Hosted and
real-device verification remain pending.
The app limits a recorded turn to five minutes and removes acknowledged upload
bytes after a complete report is saved. Pending uploads remain available for retry.
The [account isolation plan](../docs/account-isolation-plan.md) puts backend
ownership enforcement before native sign-in and defines how verified accounts
select local history partitions.

## Build, test, and run

Open `SpokenAgents.xcodeproj`, select the `SpokenAgents` scheme and an iPhone
simulator, then Build, Test, and Run. The equivalent command-line checks are:

```sh
xcodebuild -project SpokenAgents.xcodeproj -scheme SpokenAgents \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO build
xcodebuild -project SpokenAgents.xcodeproj -scheme SpokenAgents \
  -destination 'platform=iOS Simulator,name=iPhone 17' \
  CODE_SIGNING_ALLOWED=NO test
```

`project-native.yml` is the XcodeGen source for the checked-in project. Regenerate
with `xcodegen generate --spec project-native.yml` after changing target settings.

The native build is configured for the `spoken-agents-ios` public client and hosted
API. Its redirect URI is `msauth.com.zhuangxu.spokenagents.app://auth`.
The API registration exposes the delegated `access_as_user` scope, and the native
client requests it. The hosted API validates that audience, scope, and client ID.
These IDs, URLs, and scope are public configuration, not secrets. Interactive
sign-in and a hosted `/me` response still need real-device verification. The app
sends the MSAL access token
only to `API_BASE_URL`; the separate short-lived realtime credential goes only
to the provider's SDP endpoint. The native client uses the
`com.microsoft.adalcache` keychain sharing group.

## Native WebRTC variant

The checked-in project resolves `stasel/WebRTC` 153.0.0 and MSAL through Swift Package
Manager. `project.yml` remains a simulator-only fallback if the binary cannot be
downloaded; generating that variant removes the WebRTC dependency until the
native specification is regenerated. Concurrent WebRTC microphone input and
learner-only WAV recording remain a final physical-device verification item. No
Function key or provider secret is included. `API_BASE_URL` points to the hosted
API and can be overridden through a nonsecret build configuration for local work.

See the [implementation plan](../docs/ios-app-plan.md) and
[design](../docs/ios-app-design.md) for phase gates and remaining work.

Authenticator returns are handled once by the UIKit scene delegate, preserving
`sourceApplication` for MSAL broker validation. Sign-in failures show whether
Microsoft authentication or API account verification failed, with error codes
only. Real-device Authenticator round-trip verification remains required.

## iPhone diagnostics

The app persistently records UTC timestamps, launch and connection attempt IDs,
sign-in states, request routes/status/timing, microphone and audio lifecycle,
WebRTC offer/answer stages, ICE/channel states, and provider error codes. It does
not record credentials, authorization headers, query strings, request/response
bodies, SDP, audio, or conversation text. Errors include domain/code and decoding
field paths, excluding error descriptions and userInfo. Two rotating JSONL files
retain approximately 2 MB total across launches, with file protection and no
cloud backup. Diagnostics failures never block the app.

To reproduce: open the app, sign in if needed, tap Connect, then open **Diagnostics**
and **Share diagnostic log**. Refresh prepares a new snapshot. A connected,
unlocked development iPhone also allows direct retrieval without sharing:

```sh
xcrun devicectl device copy from --device <device-id> \
  --domain-type appDataContainer \
  --domain-identifier com.zhuangxu.spokenagents.app \
  --source 'Library/Application Support/Diagnostics' \
  --destination /tmp/spoken-device-diagnostics
```

Read `current.jsonl` and `previous.jsonl` in timestamp order. A `call.connect_failure`
identifies the stage; its preceding `http.response`, `http.failure`, and `rtc.*`
entries show the underlying status or state. A successful API session creation
followed by a failing provider SDP request distinguishes backend and WebRTC faults.

The first physical-device log identified successful `/me`, session creation,
and provider SDP responses, followed by route change reason 8
(`routeConfigurationChange`) during WebRTC audio setup. The app now continues
through this expected I/O configuration event; actual route-loss notifications
still stop practice. Regression tests cover both cases.
